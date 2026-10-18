-- Anifate: original Studio animation editor. Modules belong under this Script.
local function start(context, source)
	local RunService = game:GetService("RunService")
	local Selection = game:GetService("Selection")
	local Input = game:GetService("UserInputService")
	local connections, objects = {}, {}
	local widget, heartbeat, drag, selectionBox, proxy, move, rotate, updateGizmos
	local disposed, previewActive = false, false
	local toolbar = context:CreateToolbar("Anifate Animations")
	local button = toolbar:CreateButton("Anifate Animations", "Open Anifate Animations editor", "rbxassetid://136069451426043", "Anifate Animations")
	button.ClickableWhenViewportHidden = true
	button.Click:Connect(function() if widget then widget.Enabled = not widget.Enabled end end)
	local Keyframe = require(source:WaitForChild("Keyframe"))
	local Timeline = require(source:WaitForChild("Timeline"))
	local SaveLoad = require(source:WaitForChild("SaveLoad"))
	local state = {
		productName = "Anifate Animations", version = "v1",
		rig = nil, motor = nil, motors = {}, keys = {}, keyCounts = {},
		currentTime = 0, minTime = 0, maxTime = 5, duration = 5,
		isPlaying = false, looping = false, poseMode = "Rotate", editTarget = "Joints",
		autoKey = true, snapEnabled = true, fps = 30, pixelsPerSecond = 120,
		selectedMotors = {}, selectedKeys = {}, status = "Select a rig, then click Select rig",
		poses = {}, initialTransforms = {}, rigPose = CFrame.identity, undo = {}, redo = {}, clipboard = nil,
		trackIds = {}, trackLabels = {}, animationName = "", dirty = false,
		theme = "Graphite", settingsOpen = false,
	}
	local callbacks = {}
	local original, orderedMotors, orderedBones, basePivot, motorByName = {}, {}, {}, CFrame.identity, {}
	local function finite(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end
	local function round(n) return math.floor(n * 1000 + 0.5) / 1000 end
	local function within(object, rig) return object == rig or object:IsDescendantOf(rig) end
	local function trackId(joint) return assert(state.trackIds[joint], "Joint inventory changed; reselect the rig") end
	local function isPartJoint(joint)
		return joint:IsA("Motor6D") or joint:IsA("AnimationConstraint")
	end
	local function isAnimatableJoint(joint)
		return isPartJoint(joint) or joint:IsA("Bone")
	end
	local function jointPart(joint)
		if isPartJoint(joint) then return joint.Part1 end
		local ancestor = joint.Parent
		while ancestor and not ancestor:IsA("BasePart") do ancestor = ancestor.Parent end
		return ancestor
	end
	local function boneWorld(bone)
		local parent = bone.Parent
		local world = parent:IsA("Bone") and boneWorld(parent) or parent.CFrame
		return world * bone.CFrame * bone.Transform
	end
	local function pathOf(object, rig, encoded)
		local segments = {}
		while object and object ~= rig do
			local name = object.Name
			local ordinal, total = 0, 0
			for _, sibling in ipairs(object.Parent:GetChildren()) do
				if sibling.ClassName == object.ClassName and sibling.Name == object.Name then total = total + 1 end
				if sibling == object then ordinal = total end
			end
			if encoded then
				name = name:gsub("([^%w_%-])", function(character) return string.format("%%%02X", string.byte(character)) end)
				name = object.ClassName .. ":" .. name .. "[" .. ordinal .. "]"
			elseif total > 1 then name = name .. " [" .. ordinal .. "]" end
			table.insert(segments, 1, name)
			object = object.Parent
		end
		return table.concat(segments, "/")
	end
	local function boundedId(joint, path)
		if #path + 7 <= 100 then return "@Joint/" .. path end
		-- Instance.Name is limited to 100 bytes. Hash the complete escaped path,
		-- not a truncated prefix; collisions are rejected by the inventory below.
		local a, b = 2166136261, 5381
		for index = 1, #path do
			local byte = string.byte(path, index)
			a = (a * 131 + byte) % 4294967296
			b = (b * 65599 + byte) % 4294967296
		end
		return string.format("@Joint/%s/h%08x%08x", joint.ClassName, a, b)
	end
	-- A rig is an animatable hierarchy, not a particular Humanoid or body layout.
	local function resolveTracks(rig)
		assert(typeof(rig) == "Instance" and (rig:IsA("Model") or rig:IsA("BasePart")), "Select a Model or MeshPart rig")
		assert(not rig:IsA("Terrain"), "Terrain is not an animatable rig")
		local joints, counts, drivers, motors, bones = {}, {}, {}, {}, {}
		local partCount = rig:IsA("BasePart") and 1 or 0
		for _, item in ipairs(rig:GetDescendants()) do
			if item:IsA("BasePart") then partCount = partCount + 1 end
			if isAnimatableJoint(item) then
				counts[item.Name] = (counts[item.Name] or 0) + 1
				table.insert(joints, item)
				if isPartJoint(item) then
					assert(item.Part0 and item.Part1, "Disconnected Motor6D is missing Part0 or Part1: " .. item.Name)
					assert(within(item.Part0, rig) and within(item.Part1, rig), "Motor6D endpoint is outside the selected rig: " .. item.Name)
					assert(item.Part0 ~= item.Part1, "Motor6D has a self-cycle: " .. item.Name)
					assert(not drivers[item.Part1], "Two Motor6Ds drive the same part: " .. item.Part1.Name)
					drivers[item.Part1] = item; table.insert(motors, item)
				else
					assert(item.Parent:IsA("Bone") or item.Parent:IsA("BasePart"), "Bone needs a Bone or BasePart parent: " .. item.Name)
					local owner = jointPart(item)
					assert(owner and within(owner, rig), "Bone must belong to a part inside the selected rig: " .. item.Name)
					table.insert(bones, item)
				end
			end
		end
		assert(partCount > 0, "Selected rig contains no BaseParts or MeshParts")
		local order, marks = {}, {}
		local function visit(motor)
			assert(marks[motor] ~= "visiting", "Motor6D chain contains a cycle: " .. motor.Name)
			if marks[motor] then return end
			marks[motor] = "visiting"
			if drivers[motor.Part0] then visit(drivers[motor.Part0]) end
			marks[motor] = true; table.insert(order, motor)
		end
		for _, motor in ipairs(motors) do visit(motor) end
		local ids, labels, used = {}, {}, { ["@Rig"] = true }
		for _, joint in ipairs(joints) do
			local simple = counts[joint.Name] == 1 and joint.Name ~= "" and joint.Name ~= "meta" and joint.Name:sub(1, 1) ~= "@"
			local id = simple and joint.Name or boundedId(joint, pathOf(joint, rig, true))
			assert(not used[id], "Ambiguous joint identity: " .. joint.Name)
			ids[joint], labels[joint], used[id] = id, simple and joint.Name or pathOf(joint, rig, false), true
		end
		table.sort(joints, function(a, b) return ids[a] < ids[b] end)
		local function depth(bone)
			local n, parent = 0, bone.Parent
			while parent and parent:IsA("Bone") do n = n + 1; parent = parent.Parent end
			return n
		end
		table.sort(bones, function(a, b) local da, db = depth(a), depth(b); return da == db and ids[a] < ids[b] or da < db end)
		return ids, labels, joints, order, bones
	end
	state.resolveTracks = resolveTracks
	local function connect(signal, handler)
		local connection = signal:Connect(handler)
		table.insert(connections, connection)
		return connection
	end
	local function keep(object) table.insert(objects, object); return object end
	local function refresh()
		if callbacks.refreshUi then callbacks.refreshUi() end
	end
	local function status(message) state.status = message; refresh() end
	local function markDirty() state.dirty = true end
	local function ready()
		if RunService:IsRunning() then status("Anifate Animations edits poses in Edit mode, not Play mode"); return false end
		if not state.rig or not state.rig.Parent then status("No rig selected"); return false end
		return true
	end
	local function selectedMotors()
		local list = {}
		for _, motor in ipairs(state.motors) do
			if motor.Parent and state.selectedMotors[motor] then table.insert(list, motor) end
		end
		return list
	end
	local function copyKeys(keys)
		local result = {}
		for name, track in pairs(keys) do result[name] = table.clone(track) end
		return result
	end
	local function snapshot()
		return { keys = copyKeys(state.keys), poses = table.clone(state.poses),
			rigPose = state.rigPose, duration = state.duration, currentTime = state.currentTime }
	end
	local function push(before)
		table.insert(state.undo, before)
		if #state.undo > 40 then table.remove(state.undo, 1) end
		table.clear(state.redo)
	end
	local function pause()
		if heartbeat then heartbeat:Disconnect(); heartbeat = nil end
		state.isPlaying = false
		if updateGizmos then updateGizmos() end
		refresh()
	end
	updateGizmos = function()
		if not proxy then return end
		local active = previewActive and widget.Enabled and not state.isPlaying and state.rig and state.rig.Parent
		local motor = state.motor
		if active and state.editTarget == "Rig" then
			proxy.CFrame = basePivot * state.rigPose
		elseif active and motor and motor.Parent then
			if motor:IsA("Bone") then proxy.CFrame = boneWorld(motor)
			elseif motor.Part0 and motor.Part1 then proxy.CFrame = motor.Part0.CFrame * motor.C0 * motor.Transform
			else active = false end
		else active = false end
		move.Adornee = active and state.poseMode == "Move" and proxy or nil
		rotate.Adornee = active and state.poseMode == "Rotate" and proxy or nil
		selectionBox.Adornee = active and state.editTarget == "Joints" and motor and jointPart(motor) or nil
	end
	-- Edit mode does not run the deferred Motor6D simulation job. Keep Transform as
	-- animation data, then solve Part1 = Part0*C0*Transform*C1^-1 for the preview.
	local function drawPose()
		if not previewActive or not state.rig or not state.rig.Parent then return end
		local pivot = basePivot * state.rigPose
		for part, saved in pairs(original) do
			if part.Parent then
				part.Anchored = true
				part.CFrame = pivot * saved.relative
			end
		end
		for _, motor in ipairs(orderedMotors) do
			if motor.Parent and motor.Part0 and motor.Part1 then
				motor.Transform = state.poses[motor] or CFrame.identity
				motor.Part1.CFrame = motor.Part0.CFrame * motor.C0 * motor.Transform * motor.C1:Inverse()
			end
		end
		for _, bone in ipairs(orderedBones) do
			if bone.Parent then bone.Transform = state.poses[bone] or CFrame.identity end
		end
		-- Accessories follow their original attachment to animated body parts.
		for part, saved in pairs(original) do
			if part.Parent and saved.weldParent and saved.weldParent.Parent then
				part.CFrame = saved.weldParent.CFrame * saved.weldOffset
			end
		end
		updateGizmos()
	end
	local function evaluate()
		for _, motor in ipairs(state.motors) do
			local id = trackId(motor)
			if next(Keyframe.getKeys(state, id)) then
				state.poses[motor] = Keyframe.sampleAt(state, id, state.currentTime)
			end
		end
		if next(Keyframe.getKeys(state, "@Rig")) then
			state.rigPose = Keyframe.sampleAt(state, "@Rig", state.currentTime)
		end
		drawPose()
	end
	local function releasePreview()
		pause(); drag = nil; previewActive = false
		for part, saved in pairs(original) do
			if part.Parent then part.CFrame = saved.cframe; part.Anchored = saved.anchored end
		end
		for _, motor in ipairs(state.motors) do
			if motor.Parent then motor.Transform = state.initialTransforms[motor] or CFrame.identity end
		end
		updateGizmos()
	end
	local function redraw()
		Keyframe.recomputeMaxTime(state)
		state.duration = state.maxTime
		Timeline.redraw(state)
		updateGizmos()
	end
	local function restore(saved)
		pause()
		state.keys, state.poses = copyKeys(saved.keys), table.clone(saved.poses)
		state.rigPose, state.duration, state.currentTime = saved.rigPose, saved.duration, saved.currentTime
		state.selectedKeys = {}
		redraw(); drawPose()
	end
	local function keyCurrentPose()
		local time = round(state.currentTime)
		state.selectedKeys = {}
		if state.editTarget == "Rig" then
			if time > 0 and not next(Keyframe.getKeys(state, "@Rig")) then
				Keyframe.insertKey(state, "@Rig", 0, CFrame.identity)
			end
			assert(Keyframe.insertKey(state, "@Rig", time, state.rigPose))
			table.insert(state.selectedKeys, {motorName = "@Rig", time = time})
		else
			for _, motor in ipairs(selectedMotors()) do
				local id = trackId(motor)
				if time > 0 and not next(Keyframe.getKeys(state, id)) then
					Keyframe.insertKey(state, id, 0, state.initialTransforms[motor] or CFrame.identity)
				end
				assert(Keyframe.insertKey(state, id, time, state.poses[motor] or motor.Transform))
				table.insert(state.selectedKeys, {motorName = id, time = time})
			end
		end
	end
	local function changedPose(before)
		if state.autoKey then keyCurrentPose() end
		push(before); drawPose(); redraw()
		markDirty()
	end
	local function saveAnimation(name)
		if not ready() then return false, state.status end
		local success, message = SaveLoad.save(state, name)
		if success then
			state.animationName, state.dirty = message, false
			status("Saved inside " .. state.rig.Name .. ".AnifateAnimations: " .. message .. " • Save the place to keep it")
		else
			status(message)
		end
		return success, message
	end
	local function clearAnimation()
		pause()
		state.keys, state.keyCounts, state.selectedKeys = {}, {}, {}
		state.undo, state.redo, state.clipboard = {}, {}, nil
		state.poses, state.rigPose = table.clone(state.initialTransforms), CFrame.identity
		state.duration, state.currentTime = 5, 0
		state.selectedMotors, state.motor = {}, nil
		state.editTarget = #state.motors > 0 and "Joints" or "Rig"
		state.animationName, state.dirty = "", false
		redraw(); drawPose()
		Timeline.hideNewAnimationPrompt(state)
		status("New animation")
	end
	callbacks.onNewAnimationRequest = function(pendingName)
		if RunService:IsRunning() then status("Stop Play mode before creating an animation"); return end
		if type(pendingName) == "string" and pendingName ~= "" then state.animationName = pendingName end
		if state.dirty then Timeline.showNewAnimationPrompt(state) else clearAnimation() end
	end
	callbacks.onNewAnimationDecision = function(decision)
		if decision == "cancel" then
			Timeline.hideNewAnimationPrompt(state)
			return
		end
		if decision == "discard" then
			clearAnimation()
			return
		end
		if decision == "save" then
			local success = saveAnimation(state.animationName)
			if success then clearAnimation() else Timeline.showNewAnimationPrompt(state) end
		end
	end
	callbacks.onSaveShortcut = function(name)
		if not ready() then return end
		name = type(name) == "string" and name or state.animationName
		if name ~= "" then state.animationName = name end
		if type(name) ~= "string" or name:match("^%s*$") then name = "AnifateAnimation" end
		saveAnimation(name)
	end
	callbacks.onSettingsToggle = function()
		Timeline.setSettingsOpen(state, not state.settingsOpen)
	end
	callbacks.onThemeSet = function(theme)
		Timeline.setTheme(state, theme)
	end
	callbacks.onClearSelection = function()
		state.selectedMotors, state.selectedKeys, state.motor = {}, {}, nil
		updateGizmos(); refresh()
		status("Selection cleared • choose a track")
	end
	callbacks.onSelectRig = function()
		if RunService:IsRunning() then status("Stop Play mode before selecting a rig"); return end
		local candidate = Selection:Get()[1]
		if not candidate then status("Select a rig Model or MeshPart in Workspace"); return end
		if state.rig and within(candidate, state.rig) then status("Rig already selected; animation preserved"); return end
		if not candidate:IsA("Model") then
			local ancestor = candidate:FindFirstAncestorWhichIsA("Model")
			if ancestor and ancestor:IsDescendantOf(workspace) then candidate = ancestor
			elseif not candidate:IsA("BasePart") then candidate = jointPart(candidate) end
		end
		if not candidate or not candidate:IsDescendantOf(workspace) then status("Select a rig Model or MeshPart in Workspace"); return end
		if candidate == state.rig then status("Rig already selected; animation preserved"); return end
		-- Validate the whole candidate before touching the bound animation or preview.
		local ids, labels, motors, order, bones = resolveTracks(candidate)
		releasePreview()
		state.rig, state.motors, state.motor = candidate, motors, nil
		state.trackIds, state.trackLabels = ids, labels
		state.keys, state.keyCounts, state.poses, state.initialTransforms = {}, {}, {}, {}
		state.selectedMotors, state.selectedKeys = {}, {}
		state.undo, state.redo, state.clipboard = {}, {}, nil
		state.duration, state.currentTime, state.rigPose = 5, 0, CFrame.identity
		state.animationName, state.dirty = "", false
		state.editTarget = #motors == 0 and "Rig" or "Joints"
		original, basePivot, orderedMotors, orderedBones, motorByName = {}, candidate:GetPivot(), order, bones, {}
		for joint, id in pairs(ids) do motorByName[id] = joint end
		local parts = candidate:GetDescendants()
		if candidate:IsA("BasePart") then table.insert(parts, candidate) end
		for _, part in ipairs(parts) do
			if part:IsA("BasePart") then
				original[part] = {cframe = part.CFrame, relative = basePivot:ToObjectSpace(part.CFrame), anchored = part.Anchored}
			end
		end
		for _, joint in ipairs(candidate:GetDescendants()) do
			if joint:IsA("Weld") and joint.Part0 and joint.Part1 then
				local handle, body = joint.Part0, joint.Part1
				if handle:FindFirstAncestorWhichIsA("Accessory") and original[handle] then
					original[handle].weldParent = body
					original[handle].weldOffset = body.CFrame:ToObjectSpace(handle.CFrame)
				end
			end
		end
		for _, motor in ipairs(motors) do state.poses[motor] = motor.Transform; state.initialTransforms[motor] = motor.Transform end
		previewActive = widget.Enabled
		drawPose(); redraw()
		if #motors == 0 then status(candidate.Name .. " • Rigid prop: use Rig pivot. No animatable joints found")
		else
			local constraintCount = 0
			for _, joint in ipairs(order) do if joint:IsA("AnimationConstraint") then constraintCount = constraintCount + 1 end end
			status(string.format("%s • %d Motor6D/AnimationConstraint / %d Bone tracks • Choose a joint track (Ctrl-click to select multiple)", candidate.Name, #order, #bones))
		end
	end
	callbacks.onMotorSelected = function(motor, additive)
		if not ready() or not state.trackIds[motor] or motorByName[trackId(motor)] ~= motor then return end
		if not additive then state.selectedMotors = {} end
		if additive and state.selectedMotors[motor] then state.selectedMotors[motor] = nil
		else state.selectedMotors[motor] = true end
		state.motor, state.editTarget, state.selectedKeys = motor, "Joints", {}
		if not next(state.selectedMotors) then state.motor = nil end
		updateGizmos()
		status(string.format("Selected %d joint(s) • %s • %s", #selectedMotors(), state.trackLabels[motor], motor.ClassName))
	end
	callbacks.onTargetChanged = function(target)
		state.editTarget = target == "Rig" and "Rig" or "Joints"
		state.selectedKeys = {}; updateGizmos(); refresh()
	end
	callbacks.onTimeChanged = function()
		evaluate()
		state.status = string.format("%s • %s • %.3fs", state.rig and state.rig.Name or "No rig", state.editTarget, state.currentTime)
	end
	callbacks.onSetTime = function(time)
		if not finite(time) then status("Time must be a number"); return end
		pause()
		if state.snapEnabled then time = math.floor(time * state.fps + 0.5) / state.fps end
		Timeline.setPlayhead(state, round(time))
	end
	callbacks.onDurationChanged = function(value)
		if not finite(value) then status("Length must be a number"); return end
		local latest = 1
		for _, track in pairs(state.keys) do for time in pairs(track) do latest = math.max(latest, time) end end
		local duration = math.max(latest, math.clamp(value, 1, 600))
		if duration == state.duration then
			status("Length: " .. tostring(state.duration) .. "s (never trims existing keys)")
			return
		end
		local before = snapshot()
		state.duration = duration
		push(before); redraw(); markDirty()
		status("Length: " .. tostring(state.duration) .. "s (never trims existing keys)")
	end
	callbacks.onInsertKey = function()
		if not ready() then return end
		pause()
		if state.editTarget == "Joints" and #selectedMotors() == 0 then status("Select at least one joint track"); return end
		local before = snapshot(); keyCurrentPose(); push(before); redraw(); markDirty()
		status("Inserted " .. #state.selectedKeys .. " key(s)")
	end
	callbacks.onDeleteKey = function()
		if not ready() then return end
		pause()
		local targets = state.selectedKeys
		if #targets == 0 then
			targets = {}
			if state.editTarget == "Rig" then table.insert(targets, {motorName = "@Rig", time = round(state.currentTime)})
			else for _, motor in ipairs(selectedMotors()) do table.insert(targets, {motorName = trackId(motor), time = round(state.currentTime)}) end end
		end
		local before, count = snapshot(), 0
		for _, key in ipairs(targets) do if Keyframe.deleteKey(state, key.motorName, key.time) then count = count + 1 end end
		if count > 0 then push(before) end
		if count > 0 then markDirty() end
		state.selectedKeys = {}; redraw(); evaluate(); status("Deleted " .. count .. " key(s)")
	end
	callbacks.onKeySelected = function(name, time, additive)
		if not ready() or not Keyframe.getKeys(state, name)[time] then return end
		pause()
		if not additive then state.selectedKeys = {}; state.selectedMotors = {} end
		local found
		for index, key in ipairs(state.selectedKeys) do if key.motorName == name and key.time == time then found = index end end
		if found then table.remove(state.selectedKeys, found) else table.insert(state.selectedKeys, {motorName = name, time = time}) end
		state.editTarget = name == "@Rig" and "Rig" or "Joints"
		if motorByName[name] then state.motor = motorByName[name]; state.selectedMotors[state.motor] = true end
		Timeline.setPlayhead(state, time); updateGizmos(); refresh()
	end
	callbacks.onMoveKeys = function(selection, delta)
		if not ready() or not finite(delta) then return end
		pause()
		local staged, transfers, chosen = copyKeys(state.keys), {}, {}
		for _, key in ipairs(selection) do
			local value = Keyframe.getKeys(state, key.motorName)[key.time]
			local target = round(key.time + delta)
			if not value or target < 0 or target > 600 then status("Cannot move keys outside 0–600s"); return end
			table.insert(transfers, {motorName = key.motorName, time = target, value = value})
			staged[key.motorName][key.time] = nil
		end
		for _, item in ipairs(transfers) do
			if staged[item.motorName][item.time] then status("Move cancelled: a key already exists at the destination"); return end
			staged[item.motorName][item.time] = item.value
			table.insert(chosen, {motorName = item.motorName, time = item.time})
		end
		push(snapshot()); state.keys, state.selectedKeys = staged, chosen
		if #chosen > 0 then markDirty() end
		redraw(); evaluate(); status("Moved " .. #chosen .. " key(s)")
	end
	callbacks.onNumericPose = function(axis, value)
		if not ready() or not finite(value) or not state.motor then return end
		if not ({X=true,Y=true,Z=true,RX=true,RY=true,RZ=true})[axis] then return end
		pause()
		local before = snapshot()
		for _, motor in ipairs(selectedMotors()) do
			local transform = state.poses[motor] or motor.Transform
			local rx, ry, rz = transform:ToEulerAnglesXYZ()
			local fields = {X=transform.X,Y=transform.Y,Z=transform.Z,RX=rx,RY=ry,RZ=rz}
			fields[axis] = #axis == 2 and math.rad(value % 360) or math.clamp(value, -10000, 10000)
			state.poses[motor] = CFrame.new(fields.X,fields.Y,fields.Z) * CFrame.Angles(fields.RX,fields.RY,fields.RZ)
		end
		changedPose(before)
		status(state.autoKey and "Pose keyed" or "Unkeyed pose — press + Key to store")
	end
	callbacks.onResetPose = function()
		if not ready() then return end
		pause()
		if state.editTarget == "Joints" and #selectedMotors() == 0 then
			status("Select at least one joint track")
			return
		end
		local before, changed = snapshot(), false
		if state.editTarget == "Rig" then
			changed = state.rigPose ~= CFrame.identity
			state.rigPose = CFrame.identity
		else
			for _, motor in ipairs(selectedMotors()) do
				changed = changed or state.poses[motor] ~= CFrame.identity
				state.poses[motor] = CFrame.identity
			end
		end
		if not changed then status("Selected pose already reset"); return end
		changedPose(before); status("Selected pose reset")
	end
	callbacks.onCopyPose = function()
		if not ready() then return end
		local values = {}
		if state.editTarget == "Rig" then values["@Rig"] = state.rigPose
		else for _, motor in ipairs(selectedMotors()) do values[trackId(motor)] = state.poses[motor] or motor.Transform end end
		if not next(values) then status("Select joints to copy"); return end
		state.clipboard = values; status("Pose copied; change time, then Paste pose")
	end
	callbacks.onPastePose = function()
		if not ready() then return end
		if not state.clipboard then status("Copy a pose first"); return end
		pause(); local before = snapshot()
		state.selectedKeys = {}
		for name, value in pairs(state.clipboard) do
			if name == "@Rig" then state.rigPose = value
			elseif motorByName[name] then state.poses[motorByName[name]] = value end
			Keyframe.insertKey(state, name, round(state.currentTime), value)
			table.insert(state.selectedKeys, {motorName = name, time = round(state.currentTime)})
		end
		push(before); drawPose(); redraw(); markDirty(); status("Pasted pose as keyframes")
	end
	callbacks.onUndo = function()
		if not ready() then return end
		if #state.undo == 0 then status("Nothing to undo"); return end
		table.insert(state.redo, snapshot()); restore(table.remove(state.undo)); markDirty(); status("Undo")
	end
	callbacks.onRedo = function()
		if not ready() then return end
		if #state.redo == 0 then status("Nothing to redo"); return end
		table.insert(state.undo, snapshot()); restore(table.remove(state.redo)); markDirty(); status("Redo")
	end
	callbacks.onPoseModeSet = function(mode)
		if mode == "Move" or mode == "Rotate" then state.poseMode = mode end
		updateGizmos(); refresh()
	end
	callbacks.onAutoKeyToggle = function() state.autoKey = not state.autoKey; refresh() end
	callbacks.onSnapToggle = function() state.snapEnabled = not state.snapEnabled; refresh() end
	callbacks.onLoopToggle = function() state.looping = not state.looping; refresh() end
	callbacks.onPlayToggle = function()
		if state.isPlaying then pause(); return end
		if not ready() then return end
		if not next(state.keyCounts) then status("Insert a key before playing"); return end
		if state.currentTime >= state.maxTime then Timeline.setPlayhead(state, 0) end
		state.isPlaying = true; updateGizmos(); refresh()
		heartbeat = RunService.Heartbeat:Connect(function(dt)
			local ok, message = pcall(function()
				if not state.rig or not state.rig.Parent or RunService:IsRunning() then
					pause(); return
				end
				local t, ended = state.currentTime + dt, false
				if t > state.maxTime then
					if state.looping then t = t % state.maxTime else t = state.maxTime; ended = true end
				end
				Timeline.setPlayhead(state, t)
				if ended then pause(); updateGizmos() end
			end)
			if not ok then pause(); status("Playback error: " .. tostring(message)); warn(message) end
		end)
	end
	callbacks.onStop = function() pause(); Timeline.setPlayhead(state, 0); updateGizmos() end
	callbacks.onSave = function(name) saveAnimation(name) end
	callbacks.onLoad = function(name)
		if not ready() then return end
		pause(); local before = snapshot()
		local success, message = SaveLoad.load(state, name)
		if not success then status(message); return end
		push(before)
		state.poses = table.clone(state.initialTransforms); state.rigPose = CFrame.identity
		state.animationName, state.dirty = message, false
		evaluate(); redraw(); status("Loaded: " .. message)
	end
	local function exportAnimation(name)
		if #state.motors == 0 then
			return nil, "No joint tracks to export; rigid-pivot motion stays in the Anifate save"
		end
		local ok, result = pcall(function()
			name = type(name) == "string" and name:match("^%s*(.-)%s*$") or ""
			local fresh = resolveTracks(state.rig)
			for joint, id in pairs(state.trackIds) do assert(fresh[joint] == id, "Rig hierarchy changed; cannot export stale tracks") end
			for joint, id in pairs(fresh) do assert(state.trackIds[joint] == id, "Rig hierarchy changed; cannot export stale tracks") end
			local times = {[0]=true, [state.maxTime]=true}
			local count = 0
			for _, track in pairs(state.keys) do for time in pairs(track) do times[time] = true; count = count + 1 end end
			if count == 0 then error("Nothing to export; insert a key first", 0) end
			local sorted = {}; for time in pairs(times) do table.insert(sorted, time) end; table.sort(sorted)
			if #sorted > 2000 then error("Export limited to 2000 key times per clip", 0) end
			local inbound, roots, namesByParent = {}, {}, {}
			for _, motor in ipairs(orderedMotors) do inbound[motor.Part1] = true end
			for _, motor in ipairs(orderedMotors) do if not inbound[motor.Part0] then roots[motor.Part0] = true end end
			for _, bone in ipairs(orderedBones) do
				local part = jointPart(bone)
				if not inbound[part] then roots[part] = true end
			end
			local function claim(parent, poseName)
				namesByParent[parent] = namesByParent[parent] or {}
				assert(not namesByParent[parent][poseName], "Export has ambiguous sibling Pose name: " .. poseName .. "; rename those parts/bones before export")
				namesByParent[parent][poseName] = true
			end
			for part in pairs(roots) do claim("Keyframe", part.Name) end
			for _, motor in ipairs(orderedMotors) do claim(motor.Part0, motor.Part1.Name) end
			for _, bone in ipairs(orderedBones) do claim(bone.Parent, bone.Name) end
			local function sample(joint, time)
				local id = trackId(joint)
				if next(Keyframe.getKeys(state, id)) then return Keyframe.sampleAt(state, id, time) end
				return state.initialTransforms[joint] or CFrame.identity
			end
			local sequence = Instance.new("KeyframeSequence")
			sequence.Name = name ~= "" and name or "AnifateAnimation"
			sequence.Loop, sequence.Priority = state.looping, Enum.AnimationPriority.Action
			for index, time in ipairs(sorted) do
				local frame, partPoses = Instance.new("Keyframe"), {}
				frame.Time, frame.Name = time, string.format("Frame_%.3f", time)
				for part in pairs(roots) do
					local pose = Instance.new("Pose"); pose.Name = part.Name
					pose.CFrame = CFrame.identity; pose.Parent = frame
					partPoses[part] = pose
				end
				for _, motor in ipairs(orderedMotors) do
					local pose = Instance.new("Pose")
					pose.Name, pose.CFrame = motor.Part1.Name, sample(motor, time)
					pose.EasingStyle, pose.EasingDirection = Enum.PoseEasingStyle.Linear, Enum.PoseEasingDirection.InOut
					pose.Parent = partPoses[motor.Part0] or frame; partPoses[motor.Part1] = pose
				end
				for _, bone in ipairs(orderedBones) do
					local pose = Instance.new("Pose")
					pose.Name, pose.CFrame = bone.Name, sample(bone, time)
					pose.EasingStyle, pose.EasingDirection = Enum.PoseEasingStyle.Linear, Enum.PoseEasingDirection.InOut
					pose.Parent = assert(partPoses[bone.Parent], "Missing Bone export parent: " .. bone.Name)
					partPoses[bone] = pose
				end
				frame.Parent = sequence
				if index % 50 == 0 then task.wait() end
			end
			local root = game.ReplicatedStorage:FindFirstChild("AnifateExports")
			if root and not root:IsA("Folder") then sequence:Destroy(); error("AnifateExports must be a Folder", 0) end
			if not root then root = Instance.new("Folder"); root.Name = "AnifateExports"; root.Parent = game.ReplicatedStorage end
			sequence.Parent = root
			return sequence
		end)
		if not ok then return nil, tostring(result) end
		return result
	end
	callbacks.onExport = function(name)
		if not ready() then return end
		pause()
		local sequence, message = exportAnimation(name)
		if not sequence then status(message); return end
		if next(Keyframe.getKeys(state, "@Rig")) then
			status("Exported joint KeyframeSequence to ReplicatedStorage.AnifateExports; rig-pivot movement stays in the Anifate save (not uploaded)")
		else
			status("Exported KeyframeSequence to ReplicatedStorage.AnifateExports (not uploaded)")
		end
	end
	callbacks.onExportToStudio = function(name)
		if not ready() then return end
		pause()
		name = type(name) == "string" and name or state.animationName
		if name ~= "" then state.animationName = name end
		if type(name) ~= "string" or name:match("^%s*$") then name = "AnifateAnimation" end
		local sequence, message = exportAnimation(name)
		if not sequence then status(message); return end
		Selection:Set({sequence})
		local uploaded, uploadError = pcall(function() context:SaveSelectedToRoblox() end)
		if not uploaded then
			-- Fallback for Studio versions that do not expose the direct upload window.
			uploaded, uploadError = pcall(function() context:PromptSaveSelectionAsync(sequence.Name) end)
		end
		local suffix = uploaded and "Roblox's animation upload window opened" or ("open Studio's animation upload window manually (" .. tostring(uploadError) .. ")")
		if next(Keyframe.getKeys(state, "@Rig")) then
			status("Exported joint KeyframeSequence to ReplicatedStorage.AnifateExports; rig-pivot movement stays in the Anifate save; " .. suffix .. " (not automatically published)")
		else
			status("Exported KeyframeSequence to ReplicatedStorage.AnifateExports; " .. suffix .. " (not automatically published)")
		end
	end
	-- Guard asynchronous GUI callbacks as well as plugin initialization.
	for name, callback in pairs(callbacks) do
		callbacks[name] = function(...)
			if disposed then return end
			local ok, message = pcall(callback, ...)
			if not ok then pause(); status("Error: " .. tostring(message)); warn(tostring(message) .. "\n" .. debug.traceback()) end
		end
	end
	widget = keep(context:CreateDockWidgetPluginGuiAsync("AnifateOriginalEditorV3",
		DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, true, false, 1120, 560, 680, 360)))
	widget.Title = "Anifate Animations"
	Timeline.build(widget, state, callbacks)
	local gui = keep(Instance.new("Folder")); gui.Name = "AnifateViewportTools"; gui.Parent = game:GetService("CoreGui")
	proxy = keep(Instance.new("Part"))
	proxy.Name, proxy.Size = "AnifateGizmoPivot", Vector3.new(1.4,1.4,1.4)
	proxy.Transparency, proxy.Anchored, proxy.CanCollide, proxy.CanTouch, proxy.CanQuery = 1, true, false, false, false
	proxy.Archivable, proxy.Locked, proxy.Parent = false, true, workspace
	move = Instance.new("Handles"); move.Name = "Move"; move.Style = Enum.HandlesStyle.Movement
	move.Color3, move.Parent = Color3.fromRGB(68,207,222), gui
	rotate = Instance.new("ArcHandles"); rotate.Name = "Rotate"
	rotate.Axes, rotate.Color3, rotate.Parent = Axes.new(Enum.Axis.X,Enum.Axis.Y,Enum.Axis.Z), Color3.fromRGB(245,184,76), gui
	selectionBox = Instance.new("SelectionBox"); selectionBox.Color3 = Color3.fromRGB(68,207,222)
	selectionBox.LineThickness, selectionBox.SurfaceTransparency, selectionBox.Parent = 0.035, 1, gui
	local function beginPose()
		if not ready() or not previewActive then return end
		pause()
		drag = {before = snapshot(), target = state.editTarget, motors = selectedMotors(), changed = false}
	end
	local function dragPose(delta)
		if not drag then return end
		drag.changed = true
		if drag.target == "Rig" then state.rigPose = drag.before.rigPose * delta
		else
			for _, motor in ipairs(drag.motors) do state.poses[motor] = (drag.before.poses[motor] or CFrame.identity) * delta end
		end
		drawPose(); refresh()
	end
	local function endPose(cancelled)
		if not drag then return end
		local finished = drag; drag = nil
		if cancelled then restore(finished.before)
		elseif finished.changed then changedPose(finished.before); status(state.autoKey and "Pose keyed" or "Unkeyed pose — press + Key") end
	end
	connect(move.MouseButton1Down, beginPose)
	connect(rotate.MouseButton1Down, beginPose)
	connect(move.MouseDrag, function(face, distance)
		if state.snapEnabled then distance = math.floor(distance * 10 + 0.5) / 10 end
		dragPose(CFrame.new(Vector3.FromNormalId(face) * distance))
	end)
	connect(rotate.MouseDrag, function(axis, angle)
		if state.snapEnabled then angle = math.rad(math.floor(math.deg(angle) / 5 + 0.5) * 5) end
		local vector = axis == Enum.Axis.X and Vector3.xAxis or (axis == Enum.Axis.Y and Vector3.yAxis or Vector3.zAxis)
		dragPose(CFrame.fromAxisAngle(vector, angle))
	end)
	connect(move.MouseButton1Up, function() endPose(false) end)
	connect(rotate.MouseButton1Up, function() endPose(false) end)
	connect(Input.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then endPose(false) end
	end)
	connect(Input.WindowFocusReleased, function() endPose(true) end)
	local mouse = context:GetMouse()
	local function pickPart(target, additive, hit)
		for _, joint in ipairs(orderedMotors) do
			if joint.Part1 == target then callbacks.onMotorSelected(joint, additive); return end
		end
		local nearest, distance = nil, math.huge
		for _, bone in ipairs(orderedBones) do
			if jointPart(bone) == target then
				local d = (boneWorld(bone).Position - (hit or target.Position)).Magnitude
				if d < distance then nearest, distance = bone, d end
			end
		end
		if nearest then callbacks.onMotorSelected(nearest, additive)
		elseif target:IsA("BasePart") then callbacks.onClearSelection() end
	end
	connect(mouse.Button1Down, function()
		if drag or not widget.Enabled or not state.rig then return end
		local target = mouse.Target
		if target and within(target, state.rig) then
			pickPart(target, Input:IsKeyDown(Enum.KeyCode.LeftControl) or Input:IsKeyDown(Enum.KeyCode.RightControl), mouse.Hit.Position)
		end
	end)
	-- Explorer selection no longer destroys the clip. Rig changes are explicit.
	connect(Selection.SelectionChanged, function()
		if not state.rig or drag then return end
		local selected = Selection:Get()[1]
		for _, motor in ipairs(state.motors) do
			if selected == motor then callbacks.onMotorSelected(motor, false); return end
		end
		if selected and within(selected, state.rig) and selected ~= state.rig then
			if selected:IsA("BasePart") then pickPart(selected, false)
			elseif selected:IsA("Model") then callbacks.onClearSelection() end
		end
	end)
	connect(widget:GetPropertyChangedSignal("Enabled"), function()
		if widget.Enabled then
			previewActive = state.rig ~= nil
			context:Activate(true); evaluate(); refresh()
		else releasePreview(); context:Deactivate() end
		button:SetActive(widget.Enabled)
	end)
	connect(context.Deactivation, function()
		move.Adornee, rotate.Adornee, selectionBox.Adornee = nil, nil, nil
	end)
	local function shutdown()
		if disposed then return end
		releasePreview(); disposed = true
		if callbacks.disposeUi then callbacks.disposeUi() end
		for _, connection in ipairs(connections) do connection:Disconnect() end
		for index = #objects, 1, -1 do pcall(function() objects[index]:Destroy() end) end
		pcall(function() toolbar:Destroy() end)
		context:Deactivate()
	end
	connect(context.Unloading, shutdown)
	if widget.Enabled then context:Activate(true) end
	button:SetActive(widget.Enabled)
	status("Anifate Animations ready • Select a rig Model, then click Select rig")
	return {state = state, callbacks = callbacks, shutdown = shutdown, widget = widget,
		beginPose = beginPose, dragPose = dragPose, endPose = endPose, viewportTools = gui, pivot = proxy}
end

local success, result = xpcall(function()
	assert(plugin, "Save this Script and its three children as a local Studio plugin")
	return start(plugin, script)
end, debug.traceback)
if not success then
	warn("Anifate Animations initialization failed: " .. tostring(result))
else
	return result
end
