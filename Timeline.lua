local UserInputService = game:GetService("UserInputService")
local Timeline = {}
local lastUi -- Used only by the legacy, state-less play-button setter.

local GUTTER, RULER, ROW, BAR = 180, 28, 30, 10
local COLORS = {
	background = Color3.fromRGB(25, 28, 31), panel = Color3.fromRGB(32, 36, 40),
	row = Color3.fromRGB(37, 41, 45), alternate = Color3.fromRGB(33, 37, 41),
	button = Color3.fromRGB(49, 55, 60), border = Color3.fromRGB(66, 74, 79),
	text = Color3.fromRGB(232, 238, 240), muted = Color3.fromRGB(157, 172, 180),
	cyan = Color3.fromRGB(68, 207, 222), amber = Color3.fromRGB(245, 184, 76),
}
local PALETTES = {
	Graphite = {
		background = Color3.fromRGB(25, 28, 31), panel = Color3.fromRGB(32, 36, 40),
		row = Color3.fromRGB(37, 41, 45), alternate = Color3.fromRGB(33, 37, 41),
		button = Color3.fromRGB(49, 55, 60), border = Color3.fromRGB(66, 74, 79),
		text = Color3.fromRGB(232, 238, 240), muted = Color3.fromRGB(157, 172, 180),
		cyan = Color3.fromRGB(68, 207, 222), amber = Color3.fromRGB(245, 184, 76),
	},
	Slate = {
		background = Color3.fromRGB(27, 33, 40), panel = Color3.fromRGB(37, 46, 56),
		row = Color3.fromRGB(44, 54, 64), alternate = Color3.fromRGB(34, 43, 52),
		button = Color3.fromRGB(56, 68, 80), border = Color3.fromRGB(80, 98, 112),
		text = Color3.fromRGB(230, 237, 242), muted = Color3.fromRGB(160, 177, 189),
		cyan = Color3.fromRGB(102, 196, 226), amber = Color3.fromRGB(246, 190, 91),
	},
	Light = {
		background = Color3.fromRGB(242, 238, 229), panel = Color3.fromRGB(255, 251, 242),
		row = Color3.fromRGB(235, 230, 219), alternate = Color3.fromRGB(246, 242, 234),
		button = Color3.fromRGB(224, 218, 207), border = Color3.fromRGB(189, 182, 170),
		text = Color3.fromRGB(37, 42, 45), muted = Color3.fromRGB(103, 107, 105),
		cyan = Color3.fromRGB(25, 139, 160), amber = Color3.fromRGB(202, 126, 29),
	},
}

local function finite(value, fallback)
	local n = tonumber(value)
	if n and n == n and math.abs(n) < math.huge then return n end
	return fallback
end

local function create(className, parent, properties)
	local object = Instance.new(className)
	for name, value in pairs(properties) do object[name] = value end
	object.Parent = parent
	return object
end

local function text(className, parent, name, caption, width)
	return create(className, parent, {
		Name = name, Text = caption, Size = UDim2.fromOffset(width, 26),
		BackgroundColor3 = COLORS.button, BorderSizePixel = 0,
		TextColor3 = COLORS.text, Font = Enum.Font.SourceSans, TextSize = 15,
	})
end

local function connect(ui, signal, handler, bucket)
	local connection = signal:Connect(handler)
	table.insert(ui.connections, connection)
	if bucket and bucket ~= ui.connections then table.insert(bucket, connection) end
	return connection
end

local function disconnect(connections, master)
	for _, connection in ipairs(connections) do connection:Disconnect() end
	if master and master ~= connections then
		for index = #master, 1, -1 do
			for _, connection in ipairs(connections) do
				if master[index] == connection then table.remove(master, index); break end
			end
		end
	end
	table.clear(connections)
end

local function releaseConnection(ui, connection)
	if not connection then return end
	connection:Disconnect()
	for index = #ui.connections, 1, -1 do
		if ui.connections[index] == connection then table.remove(ui.connections, index) end
	end
end

local function invoke(ui, name, ...)
	if ui.disposed then return end
	local callback = ui.callbacks[name]
	if type(callback) == "function" then
		local ok, message = pcall(callback, ...)
		if not ok then warn("Anifate Timeline / " .. name .. ": " .. tostring(message)) end
	end
end

local function additive()
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
end

local function primary(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

local function selectionMap(selection)
	local result = {}
	for _, key in ipairs(selection or {}) do
		if type(key.motorName) == "string" and type(key.time) == "number" and finite(key.time) then
			result[key.motorName] = result[key.motorName] or {}
			result[key.motorName][key.time] = true
		end
	end
	return result
end

local function selected(map, name, time)
	return map[name] and map[name][time] == true
end

local function normalize(state)
	state.motors, state.keys = state.motors or {}, state.keys or {}
	state.selectedMotors, state.selectedKeys = state.selectedMotors or {}, state.selectedKeys or {}
	state.fps = math.clamp(math.floor(finite(state.fps, 30) + 0.5), 1, 240)
	state.duration = math.clamp(finite(state.duration, 5), 1 / state.fps, 600)
	state.pixelsPerSecond = math.clamp(finite(state.pixelsPerSecond, 120), 40, 480)
	state.minTime = 0
	local latest = 0
	for _, keys in pairs(state.keys) do
		for time in pairs(keys) do
			if type(time) == "number" and finite(time) then latest = math.max(latest, time) end
		end
	end
	state.maxTime = math.max(state.duration, latest)
	state.currentTime = math.clamp(finite(state.currentTime, 0), 0, state.maxTime)
	state.poseMode, state.editTarget = state.poseMode or "Rotate", state.editTarget or "Joints"
	state.theme = PALETTES[state.theme] and state.theme or "Graphite"
	if state.settingsOpen == nil then state.settingsOpen = false end
	if state.isPlaying == nil then state.isPlaying = false end
	if state.looping == nil then state.looping = false end
	if state.autoKey == nil then state.autoKey = true end
	if state.snapEnabled == nil then state.snapEnabled = true end
end

local function snapped(state, time)
	if state.snapEnabled then return math.floor(time * state.fps + 0.5) / state.fps end
	return time
end

local function writeBox(box, value)
	if not box:IsFocused() then box.Text = value end
end

local function cleanText(value)
	return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function highlight(button, active, color)
	button.BackgroundColor3 = active and (color or COLORS.cyan) or COLORS.button
	button.TextColor3 = active and COLORS.background or COLORS.text
end

local refresh, renderVisible, beginScrub, beginKey, moveGesture, finishGesture

local function applyTheme(state, ui)
	local palette = PALETTES[state.theme] or PALETTES.Graphite
	state.theme = PALETTES[state.theme] and state.theme or "Graphite"
	for name, color in pairs(palette) do COLORS[name] = color end
	if not ui or ui.disposed or not ui.root then return end

	ui.root.BackgroundColor3 = COLORS.background
	for _, object in ipairs(ui.root:GetDescendants()) do
		if object:IsA("ScrollingFrame") then
			object.BackgroundColor3 = object.Name == "TimelineCanvas" and COLORS.background or COLORS.panel
			object.ScrollBarImageColor3 = COLORS.muted
		elseif object:IsA("TextButton") then
			if object.Name == "KeyDiamond" then
				object.BackgroundColor3 = COLORS.amber
			elseif object.Name == "TrackName" then
				object.BackgroundColor3 = COLORS.panel
			else
				object.BackgroundColor3 = COLORS.button
			end
			object.TextColor3 = COLORS.text
		elseif object:IsA("TextBox") then
			object.BackgroundColor3 = COLORS.background
			object.TextColor3 = COLORS.text
			object.PlaceholderColor3 = COLORS.muted
		elseif object:IsA("TextLabel") then
			object.TextColor3 = COLORS.text
			if object.Name == "Heading" or object.Name == "SettingsTitle" or object.Name == "PromptTitle" then
				object.TextColor3 = COLORS.cyan
			elseif object.Name == "GutterHeading" or object.Name == "Second"
				or object.Name == "Label" or object.Name == "KeyCount" or object.Name == "Zoom"
				or object.Name == "ThemeLabel"
				or object.Name == "ShortcutHelp" then
				object.TextColor3 = COLORS.muted
			end
			if object.Name == "Status" or object.Name == "GutterHeading" or object.Name == "KeyCount" then
				object.BackgroundColor3 = COLORS.panel
			end
		elseif object:IsA("Frame") then
			if object.Name == "Track" then
				object.BackgroundColor3 = COLORS.row
			elseif object.Name == "Ruler" or object.Name == "SettingsPanel"
				or object.Name == "NewAnimationPrompt" then
				object.BackgroundColor3 = COLORS.panel
				object.BorderColor3 = COLORS.border
			elseif object.Name == "Playhead" then
				object.BackgroundColor3 = COLORS.amber
			elseif object.Name == "Tick" then
				object.BackgroundColor3 = COLORS.border
			end
		end
	end
	for index, row in ipairs(ui.rows or {}) do
		if row.track then row.track.BackgroundColor3 = index % 2 == 1 and COLORS.row or COLORS.alternate end
	end
	for theme, button in pairs(ui.themeButtons or {}) do
		highlight(button, state.theme == theme)
	end
	if ui.buttons.settings then highlight(ui.buttons.settings, state.settingsOpen) end
end

local function setSettingsVisible(ui, isOpen)
	if ui.disposed or not ui.settingsPanel then return end
	ui.state.settingsOpen = not not isOpen
	ui.settingsPanel.Visible = ui.state.settingsOpen
	if ui.buttons.settings then highlight(ui.buttons.settings, ui.state.settingsOpen) end
end

local function toggleSettings(ui)
	if ui.disposed then return end
	local wasOpen = ui.state.settingsOpen == true
	invoke(ui, "onSettingsToggle")
	if ui.disposed then return end
	if ui.state.settingsOpen == wasOpen then setSettingsVisible(ui, not wasOpen)
	else setSettingsVisible(ui, ui.state.settingsOpen) end
end

local function keyboardShortcut(ui, input, gameProcessed)
	if ui.disposed or gameProcessed or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	if UserInputService:GetFocusedTextBox() then return end
	local key, handled = input.KeyCode, false
	if additive() then
		if key == Enum.KeyCode.Z then invoke(ui, "onUndo"); handled = true
		elseif key == Enum.KeyCode.Y then invoke(ui, "onRedo"); handled = true
		elseif key == Enum.KeyCode.C then invoke(ui, "onCopyPose"); handled = true
		elseif key == Enum.KeyCode.V then invoke(ui, "onPastePose"); handled = true
		elseif key == Enum.KeyCode.S then invoke(ui, "onSaveShortcut", cleanText(ui.nameBox and ui.nameBox.Text)); handled = true
		elseif key == Enum.KeyCode.N then invoke(ui, "onNewAnimationRequest", cleanText(ui.nameBox and ui.nameBox.Text)); handled = true
		elseif key == Enum.KeyCode.E then invoke(ui, "onExportToStudio", cleanText(ui.nameBox and ui.nameBox.Text)); handled = true end
	end
	if not handled then
		if key == Enum.KeyCode.R then invoke(ui, "onPoseModeSet", "Rotate"); handled = true
		elseif key == Enum.KeyCode.M then invoke(ui, "onPoseModeSet", "Move"); handled = true
		elseif key == Enum.KeyCode.Space then invoke(ui, "onPlayToggle"); handled = true
		elseif key == Enum.KeyCode.I then invoke(ui, "onInsertKey"); handled = true
		elseif key == Enum.KeyCode.Delete or key == Enum.KeyCode.Backspace then invoke(ui, "onDeleteKey"); handled = true
		elseif key == Enum.KeyCode.G then toggleSettings(ui); handled = true end
	end
	if handled and not ui.disposed then refresh(ui) end
end

refresh = function(ui)
	if ui.disposed then return end
	local state, buttons = ui.state, ui.buttons
	applyTheme(state, ui)
	buttons.play.Text = state.isPlaying and "Pause" or "Play"
	highlight(buttons.play, state.isPlaying)
	highlight(buttons.loop, state.looping)
	highlight(buttons.rig, state.editTarget == "Rig")
	highlight(buttons.joints, state.editTarget == "Joints")
	highlight(buttons.rotate, state.poseMode == "Rotate")
	highlight(buttons.move, state.poseMode == "Move")
	highlight(buttons.auto, state.autoKey, COLORS.amber)
	highlight(buttons.snap, state.snapEnabled)
	writeBox(ui.timeBox, string.format("%.3f", state.currentTime))
	writeBox(ui.durationBox, string.format("%.3f", state.duration))
	if ui.nameBox then writeBox(ui.nameBox, state.animationName or "") end
	ui.fps.Text = tostring(state.fps) .. " FPS"
	ui.zoom.Text = tostring(math.floor(state.pixelsPerSecond)) .. " px/s"
	local animationName = tostring(state.animationName or "Untitled")
	if animationName == "" then animationName = "Untitled" end
	local dirtyMark = state.dirty and "*" or ""
	ui.heading.Text = (state.productName or "ANIFATE ANIMATIONS") .. (state.version and (" " .. state.version) or "") .. "  /  "
		.. (state.rig and state.rig.Name or "Select a rig to begin") .. "  /  " .. animationName .. dirtyMark
	ui.status.Text = "  " .. tostring(state.status or "Ready • Ctrl-click to extend selection • Drag keys to retime")
		.. "  /  " .. animationName .. dirtyMark
	if ui.settingsPanel then ui.settingsPanel.Visible = state.settingsOpen == true end
	if ui.themeButtons then
		for theme, button in pairs(ui.themeButtons) do highlight(button, state.theme == theme) end
	end
	if buttons.settings then highlight(buttons.settings, state.settingsOpen) end
	ui.playhead.Position = UDim2.fromOffset(GUTTER + state.currentTime * state.pixelsPerSecond, 0)
	local map = selectionMap(state.selectedKeys)
	for _, row in ipairs(ui.rows) do
		local active = row.motor and (state.selectedMotors[row.motor] or state.motor == row.motor)
		row.button.TextColor3 = active and COLORS.cyan or COLORS.text
		row.count.Text = tostring((state.keyCounts or {})[row.name] or #row.times)
	end
	for _, view in ipairs(ui.keyViews) do
		view.button.BackgroundColor3 = selected(map, view.name, view.time) and COLORS.cyan or COLORS.amber
	end
	local editable = state.editTarget == "Joints" and state.motor and state.motor.Parent ~= nil
	local values = {}
	if editable then
		local transform = state.motor.Transform
		local rx, ry, rz = transform:ToEulerAnglesXYZ()
		values = { X = transform.X, Y = transform.Y, Z = transform.Z,
			RX = math.deg(rx), RY = math.deg(ry), RZ = math.deg(rz) }
	end
	for axis, box in pairs(ui.poseBoxes) do
		box.TextEditable = not not editable
		box.TextColor3 = editable and COLORS.text or COLORS.muted
		writeBox(box, editable and string.format("%.3f", values[axis]) or "—")
	end
end

-- Only visible ticks and diamonds are instantiated; the canvas still spans the full clip.
renderVisible = function(ui)
	if ui.disposed then return end
	applyTheme(ui.state, ui)
	disconnect(ui.visibleConnections, ui.connections)
	ui.dynamic:ClearAllChildren()
	ui.keyViews = {}
	local state, canvas = ui.state, ui.canvas
	local pan, window, scale = canvas.CanvasPosition, canvas.AbsoluteWindowSize, state.pixelsPerSecond
	local first = math.max(0, math.floor((pan.X - GUTTER) / scale * 4))
	local last = math.min(math.floor(state.maxTime * 4), math.ceil((pan.X + window.X - GUTTER) / scale * 4))
	local stride = math.max(1, math.ceil((last - first + 1) / 240))
	for index = first, last, stride do
		local x, major = GUTTER + index * 0.25 * scale, index % 4 == 0
		create("Frame", ui.dynamic, {
			Name = "Tick", Position = UDim2.fromOffset(x, 0), Size = UDim2.new(0, 1, 1, 0),
			BackgroundColor3 = COLORS.border, BackgroundTransparency = major and 0.35 or 0.75,
			BorderSizePixel = 0, ZIndex = 2,
		})
		if major then
			local label = text("TextLabel", ui.dynamic, "Second", tostring(index / 4) .. "s", 54)
			label.Position, label.BackgroundTransparency = UDim2.fromOffset(x + 4, 0), 1
			label.TextXAlignment, label.TextColor3, label.ZIndex = Enum.TextXAlignment.Left, COLORS.muted, 3
		end
	end
	local map, gesture = selectionMap(state.selectedKeys), ui.gesture
	for _, row in ipairs(ui.rows) do
		if row.y + ROW >= pan.Y and row.y <= pan.Y + window.Y then
			for _, time in ipairs(row.times) do
				local preview = gesture and gesture.kind == "keys" and selected(gesture.map, row.name, time)
				local x = GUTTER + (time + (preview and gesture.delta or 0)) * scale
				if x >= pan.X - 12 and x <= pan.X + window.X + 12 then
					local key = text("TextButton", ui.dynamic, "KeyDiamond", "", 12)
					key.Size, key.AnchorPoint = UDim2.fromOffset(12, 12), Vector2.new(0.5, 0.5)
					key.Position, key.Rotation = UDim2.fromOffset(x, row.y + ROW / 2), 45
					key.BackgroundColor3 = selected(map, row.name, time) and COLORS.cyan or COLORS.amber
					key.AutoButtonColor, key.ZIndex = false, 5
					table.insert(ui.keyViews, { button = key, name = row.name, time = time })
					connect(ui, key.InputBegan, function(input) beginKey(ui, input, row.name, time) end, ui.visibleConnections)
				end
			end
		end
	end
end

function Timeline.redraw(state)
	local ui = state.ui
	if not ui or ui.disposed then return end
	normalize(state)
	applyTheme(state, ui)
	disconnect(ui.rowConnections, ui.connections)
	ui.rowsLayer:ClearAllChildren()
	ui.rows = {}
	local width = math.max(GUTTER + state.maxTime * state.pixelsPerSecond + 28, ui.canvas.AbsoluteWindowSize.X)
	local height = math.max(RULER + (#state.motors + 1) * ROW, ui.canvas.AbsoluteWindowSize.Y)
	ui.canvas.CanvasSize, ui.content.Size = UDim2.fromOffset(width, height), UDim2.fromOffset(width, height)
	local function addRow(motor, name, caption)
		local y = RULER + #ui.rows * ROW
		local track = create("Frame", ui.rowsLayer, {
			Name = "Track", Position = UDim2.fromOffset(GUTTER, y),
			Size = UDim2.fromOffset(width - GUTTER, ROW), BorderSizePixel = 0,
			BackgroundColor3 = #ui.rows % 2 == 0 and COLORS.row or COLORS.alternate, Active = true,
		})
		local button = text("TextButton", ui.rowsLayer, "TrackName", "  " .. caption, GUTTER - 44)
		button.Position, button.Size = UDim2.fromOffset(0, y), UDim2.fromOffset(GUTTER - 44, ROW)
		button.TextXAlignment, button.TextTruncate = Enum.TextXAlignment.Left, Enum.TextTruncate.AtEnd
		button.BackgroundColor3, button.ZIndex = COLORS.panel, 4
		local count = text("TextLabel", ui.rowsLayer, "KeyCount", "", 44)
		count.Position, count.Size = UDim2.fromOffset(GUTTER - 44, y), UDim2.fromOffset(44, ROW)
		count.BackgroundColor3, count.TextColor3, count.ZIndex = COLORS.panel, COLORS.muted, 4
		local times = {}
		for time in pairs(state.keys[name] or {}) do
			if type(time) == "number" and finite(time) and time >= 0 then table.insert(times, time) end
		end
		table.sort(times)
		table.insert(ui.rows, { motor = motor, name = name, y = y, times = times, button = button, count = count, track = track })
		connect(ui, button.MouseButton1Click, function()
			if motor then invoke(ui, "onMotorSelected", motor, additive())
			else invoke(ui, "onTargetChanged", "Rig") end
			refresh(ui)
		end, ui.rowConnections)
		connect(ui, track.InputBegan, function(input) beginScrub(ui, input) end, ui.rowConnections)
	end
	addRow(nil, "@Rig", "Rig pivot")
	for _, motor in ipairs(state.motors) do
		local name = (state.trackIds and state.trackIds[motor]) or motor.Name
		local label = (state.trackLabels and state.trackLabels[motor]) or motor.Name
		local kind = motor:IsA("Bone") and "Bone" or (motor:IsA("AnimationConstraint") and "AnimationConstraint" or "Motor6D")
		addRow(motor, name, label .. " [" .. kind .. "]")
	end
	renderVisible(ui)
	refresh(ui)
end

local function insideCanvas(ui, position)
	local point = Vector2.new(position.X, position.Y) - ui.canvas.AbsolutePosition
	local size = ui.canvas.AbsoluteWindowSize
	return point.X >= 0 and point.Y >= 0 and point.X < size.X and point.Y < size.Y
end

local function isKeyAt(ui, position)
	for _, view in ipairs(ui.keyViews) do
		local center = view.button.AbsolutePosition + view.button.AbsoluteSize / 2
		if math.abs(position.X - center.X) <= 11 and math.abs(position.Y - center.Y) <= 11 then return true end
	end
	return false
end

local function isTrackAt(ui, position)
	local point = Vector2.new(position.X, position.Y) - ui.canvas.AbsolutePosition + ui.canvas.CanvasPosition
	for _, row in ipairs(ui.rows) do
		if point.Y >= row.y and point.Y < row.y + ROW then return true end
	end
	return false
end

local function requestTime(ui, x)
	local state, canvas = ui.state, ui.canvas
	local time = (x - canvas.AbsolutePosition.X + canvas.CanvasPosition.X - GUTTER) / state.pixelsPerSecond
	invoke(ui, "onSetTime", math.clamp(snapped(state, time), 0, state.maxTime))
	refresh(ui)
end

local function startGesture(ui, input, gesture)
	gesture.input, gesture.startX = input, input.Position.X
	gesture.startPan, gesture.scale = ui.canvas.CanvasPosition.X, ui.state.pixelsPerSecond
	gesture.scrolling = ui.canvas.ScrollingEnabled
	ui.gesture, ui.canvas.ScrollingEnabled = gesture, false
	-- The originating input can end even when the pointer has left the widget.
	gesture.connection = connect(ui, input:GetPropertyChangedSignal("UserInputState"), function()
		if ui.gesture ~= gesture then return end
		if input.UserInputState == Enum.UserInputState.End then
			moveGesture(ui, input.Position.X)
			finishGesture(ui, false)
		elseif input.UserInputState == Enum.UserInputState.Cancel then
			finishGesture(ui, true)
		end
	end)
end

beginScrub = function(ui, input)
	if ui.disposed or ui.gesture or not primary(input) or not insideCanvas(ui, input.Position) then return end
	local x = input.Position.X - ui.canvas.AbsolutePosition.X + ui.canvas.CanvasPosition.X
	-- Background signals may also fire beneath descendants. Explicitly exclude diamonds.
	if isKeyAt(ui, input.Position) then return end
	if not isTrackAt(ui, input.Position) then
		invoke(ui, "onClearSelection")
		if ui.disposed then return end
	end
	if x < GUTTER then return end
	startGesture(ui, input, { kind = "scrub" })
	requestTime(ui, input.Position.X)
end

beginKey = function(ui, input, name, time)
	if ui.disposed or ui.gesture or not primary(input) or not insideCanvas(ui, input.Position) then return end
	local ctrl = additive()
	local wasSelected = selected(selectionMap(ui.state.selectedKeys), name, time)
	if ctrl or not wasSelected then invoke(ui, "onKeySelected", name, time, ctrl) end
	if ui.disposed then return end
	refresh(ui)
	local original, earliest, latest = {}, math.huge, 0
	for _, key in ipairs(ui.state.selectedKeys) do
		if type(key.motorName) == "string" and type(key.time) == "number" and finite(key.time) then
			table.insert(original, { motorName = key.motorName, time = key.time })
			earliest, latest = math.min(earliest, key.time), math.max(latest, key.time)
		end
	end
	local map = selectionMap(original)
	if not selected(map, name, time) then return end -- Ctrl may have deselected this key.
	startGesture(ui, input, { kind = "keys", original = original, map = map, delta = 0,
		earliest = earliest, latest = latest, anchor = time, name = name, collapse = wasSelected and not ctrl })
end

moveGesture = function(ui, x)
	local gesture = ui.gesture
	if not gesture then return end
	if gesture.kind == "scrub" then requestTime(ui, x); return end
	local pixels = x - gesture.startX + ui.canvas.CanvasPosition.X - gesture.startPan
	if math.abs(pixels) >= 4 then gesture.moved = true end
	if not gesture.moved then return end
	local delta = snapped(ui.state, gesture.anchor + pixels / gesture.scale) - gesture.anchor
	gesture.delta = math.clamp(delta, -gesture.earliest, math.max(600, gesture.latest) - gesture.latest)
	-- Preview only: neither state.keys nor state.selectedKeys is modified during motion.
	for _, view in ipairs(ui.keyViews) do
		if selected(gesture.map, view.name, view.time) then
			view.button.Position = UDim2.fromOffset(GUTTER + (view.time + gesture.delta) * gesture.scale,
				view.button.Position.Y.Offset)
		end
	end
end

finishGesture = function(ui, cancelled)
	local gesture = ui.gesture
	if not gesture then return end
	if gesture.connection then releaseConnection(ui, gesture.connection) end
	ui.gesture, ui.canvas.ScrollingEnabled = nil, gesture.scrolling
	if gesture.kind == "keys" then
		if not cancelled then
			if gesture.moved and math.abs(gesture.delta) > 0.0000001 then
				invoke(ui, "onMoveKeys", gesture.original, gesture.delta)
			elseif not gesture.moved and gesture.collapse then
				invoke(ui, "onKeySelected", gesture.name, gesture.anchor, false)
			end
		end
		if not ui.disposed then Timeline.redraw(ui.state) end
	end
end

local function zoom(ui, factor)
	if ui.gesture then return end
	local state, canvas = ui.state, ui.canvas
	local anchor = math.clamp(GUTTER + state.currentTime * state.pixelsPerSecond - canvas.CanvasPosition.X,
		0, math.max(0, canvas.AbsoluteWindowSize.X - 1))
	local y = canvas.CanvasPosition.Y
	state.pixelsPerSecond = math.clamp(state.pixelsPerSecond * factor, 40, 480)
	Timeline.redraw(state)
	local x = GUTTER + state.currentTime * state.pixelsPerSecond - anchor
	canvas.CanvasPosition = Vector2.new(math.clamp(x, 0, math.max(0, canvas.CanvasSize.X.Offset - canvas.AbsoluteWindowSize.X)), y)
	renderVisible(ui)
end

function Timeline.build(parent, state, callbacks)
	-- Owner callbacks update state synchronously. Structural edits should call redraw;
	-- refreshUi only updates existing visuals. Keys are keys[canonicalTrackId][numericTime].
	if state.ui and state.ui.dispose then state.ui.dispose() end
	normalize(state)
	applyTheme(state)
	local ui = { state = state, callbacks = callbacks or {}, connections = {}, rowConnections = {},
		visibleConnections = {}, rows = {}, keyViews = {}, buttons = {}, poseBoxes = {}, themeButtons = {} }
	state.ui, lastUi = ui, ui
	ui.root = create("Frame", parent, { Name = "AnifateEditor", Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = COLORS.background, BorderSizePixel = 0, ClipsDescendants = true })
	ui.heading = text("TextLabel", ui.root, "Heading", "ANIFATE ANIMATIONS v1", 300)
	ui.heading.Position, ui.heading.Size = UDim2.fromOffset(10, 0), UDim2.new(1, -20, 0, 24)
	ui.heading.BackgroundTransparency, ui.heading.TextXAlignment = 1, Enum.TextXAlignment.Left
	ui.heading.Font, ui.heading.TextColor3 = Enum.Font.SourceSansBold, COLORS.cyan
	ui.heading.TextTruncate = Enum.TextTruncate.AtEnd
	local function toolbar(y, name)
		local bar = create("ScrollingFrame", ui.root, { Name = name, Position = UDim2.fromOffset(6, y),
			Size = UDim2.new(1, -12, 0, 40), BackgroundColor3 = COLORS.panel, BorderSizePixel = 0,
			CanvasSize = UDim2.fromOffset(0, 0), ScrollBarThickness = 6, ScrollBarImageColor3 = COLORS.muted,
			ScrollingDirection = Enum.ScrollingDirection.X, HorizontalScrollBarInset = Enum.ScrollBarInset.Always,
			ElasticBehavior = Enum.ElasticBehavior.Never })
		create("UIPadding", bar, { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) })
		local layout = create("UIListLayout", bar, { FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) })
		connect(ui, layout:GetPropertyChangedSignal("AbsoluteContentSize"), function()
			bar.CanvasSize = UDim2.fromOffset(layout.AbsoluteContentSize.X + 12, 0)
		end)
		return bar
	end
	local first, second = toolbar(24, "EditingTools"), toolbar(66, "TransportAndPose")
	local function item(className, bar, name, caption, width)
		local object = text(className, bar, name, caption, width)
		object.LayoutOrder = #bar:GetChildren()
		return object
	end
	local function action(bar, id, caption, width, callback, argument)
		local button = item("TextButton", bar, id, caption, width)
		ui.buttons[id] = button
		connect(ui, button.MouseButton1Click, function()
			if type(callback) == "function" then callback()
			elseif argument ~= nil then invoke(ui, callback, argument)
			else invoke(ui, callback) end
			refresh(ui)
		end)
		return button
	end
	local function box(bar, name, width)
		local field = item("TextBox", bar, name, "", width)
		field.ClearTextOnFocus, field.BackgroundColor3 = false, COLORS.background
		field.PlaceholderColor3 = COLORS.muted
		return field
	end
	local function caption(bar, value, width)
		local label = item("TextLabel", bar, "Label", value, width)
		label.BackgroundTransparency, label.TextColor3 = 1, COLORS.muted
		return label
	end
	action(first, "newAnimation", "New", 54, function()
		state.animationName = cleanText(ui.nameBox.Text)
		invoke(ui, "onNewAnimationRequest", state.animationName)
	end)
	action(first, "settings", "⚙ Settings", 92, function() toggleSettings(ui) end)
	action(first, "exportToStudio", "Publish Animation", 124, function()
		invoke(ui, "onExportToStudio", cleanText(ui.nameBox.Text))
	end)
	action(first, "select", "Select rig", 84, "onSelectRig")
	action(first, "joints", "Joints", 60, "onTargetChanged", "Joints")
	action(first, "rig", "Rig pivot", 76, "onTargetChanged", "Rig")
	action(first, "rotate", "Rotate", 62, "onPoseModeSet", "Rotate")
	action(first, "move", "Move", 56, "onPoseModeSet", "Move")
	action(first, "auto", "Auto key", 72, "onAutoKeyToggle")
	action(first, "snap", "Snap", 54, "onSnapToggle")
	action(first, "copy", "Copy pose", 82, "onCopyPose")
	action(first, "paste", "Paste pose", 82, "onPastePose")
	action(first, "undo", "Undo", 52, "onUndo")
	action(first, "redo", "Redo", 52, "onRedo")
	ui.nameBox = box(first, "AnimationName", 144)
	ui.nameBox.PlaceholderText = "Animation name"
	local function namedCallback(name)
		return function()
			state.animationName = cleanText(ui.nameBox.Text)
			invoke(ui, name, state.animationName)
		end
	end
	action(first, "save", "Save", 52, namedCallback("onSave"))
	action(first, "load", "Load", 52, namedCallback("onLoad"))
	action(first, "export", "Export", 62, namedCallback("onExport"))
	action(second, "play", "Play", 58, "onPlayToggle")
	action(second, "stop", "Stop", 54, "onStop")
	action(second, "loop", "Loop", 54, "onLoopToggle")
	action(second, "insert", "+ Key", 58, "onInsertKey")
	action(second, "delete", "− Key", 58, "onDeleteKey")
	caption(second, "Time s", 44)
	ui.timeBox = box(second, "CurrentTime", 76)
	caption(second, "Length s", 56)
	ui.durationBox = box(second, "Duration", 76)
	action(second, "zoomOut", "−", 28, function() zoom(ui, 1 / 1.25) end)
	ui.zoom = caption(second, "", 66)
	action(second, "zoomIn", "+", 28, function() zoom(ui, 1.25) end)
	ui.fps = caption(second, "", 54)
	caption(second, "LOCAL JOINT", 92)
	for _, axis in ipairs({ "X", "Y", "Z", "RX", "RY", "RZ" }) do
		caption(second, axis .. (#axis == 2 and "°" or ""), 30)
		local field = box(second, axis, 66)
		ui.poseBoxes[axis] = field
		local editingMotor
		connect(ui, field.Focused, function() editingMotor = state.motor end)
		connect(ui, field.FocusLost, function()
			local value = finite(field.Text)
			if value and state.editTarget == "Joints" and state.motor == editingMotor
				and state.motor and state.motor.Parent then
				-- XYZ Euler degrees describe the selected joint's local Transform.
				invoke(ui, "onNumericPose", axis, value)
			end
			editingMotor = nil
			refresh(ui)
		end)
	end
	action(second, "reset", "Reset pose", 82, "onResetPose")
	connect(ui, ui.timeBox.FocusLost, function()
		local value = finite(ui.timeBox.Text)
		if value then invoke(ui, "onSetTime", math.clamp(snapped(state, value), 0, state.maxTime)) end
		refresh(ui)
	end)
	connect(ui, ui.durationBox.FocusLost, function()
		local value = finite(ui.durationBox.Text)
		if value then invoke(ui, "onDurationChanged", math.clamp(value, 1 / state.fps, 600)) end
		if not ui.disposed then Timeline.redraw(state) end
	end)
	ui.canvas = create("ScrollingFrame", ui.root, { Name = "TimelineCanvas", Position = UDim2.fromOffset(6, 114),
		Size = UDim2.new(1, -12, 1, -154), BackgroundColor3 = COLORS.background, BorderSizePixel = 0,
		CanvasSize = UDim2.fromOffset(0, 0), ScrollingDirection = Enum.ScrollingDirection.XY,
		ScrollBarThickness = BAR, ScrollBarImageColor3 = COLORS.muted, Active = true,
		HorizontalScrollBarInset = Enum.ScrollBarInset.Always, VerticalScrollBarInset = Enum.ScrollBarInset.Always,
		ElasticBehavior = Enum.ElasticBehavior.Never })
	ui.content = create("Frame", ui.canvas, { Name = "CanvasContent", BackgroundTransparency = 1, BorderSizePixel = 0 })
	ui.rowsLayer = create("Frame", ui.content, { Name = "Tracks", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 })
	local ruler = create("Frame", ui.content, { Name = "Ruler", Size = UDim2.new(1, 0, 0, RULER),
		BackgroundColor3 = COLORS.panel, BorderSizePixel = 0, Active = true })
	local gutter = text("TextLabel", ruler, "GutterHeading", "  TRACK / KEYS", GUTTER)
	gutter.Size, gutter.TextXAlignment = UDim2.fromOffset(GUTTER, RULER), Enum.TextXAlignment.Left
	gutter.BackgroundColor3, gutter.TextColor3, gutter.ZIndex = COLORS.panel, COLORS.muted, 4
	ui.dynamic = create("Frame", ui.content, { Name = "VisibleMarks", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 })
	ui.playhead = create("Frame", ui.content, { Name = "Playhead", Size = UDim2.new(0, 2, 1, 0),
		BackgroundColor3 = COLORS.amber, BorderSizePixel = 0, ZIndex = 6 })
	ui.status = text("TextLabel", ui.root, "Status", "", 300)
	ui.status.Position, ui.status.Size = UDim2.new(0, 6, 1, -36), UDim2.new(1, -12, 0, 32)
	ui.status.BackgroundColor3, ui.status.TextXAlignment = COLORS.panel, Enum.TextXAlignment.Left
	ui.status.TextWrapped = true
	ui.settingsPanel = create("Frame", ui.root, { Name = "SettingsPanel",
		Position = UDim2.fromOffset(18, 112), Size = UDim2.fromOffset(350, 226),
		BackgroundColor3 = COLORS.panel, BorderColor3 = COLORS.border, BorderSizePixel = 1,
		Visible = state.settingsOpen, Active = true, ZIndex = 20 })
	local settingsTitle = text("TextLabel", ui.settingsPanel, "SettingsTitle", "SETTINGS", 320)
	settingsTitle.Position, settingsTitle.Size = UDim2.fromOffset(14, 8), UDim2.fromOffset(320, 24)
	settingsTitle.BackgroundTransparency, settingsTitle.TextColor3 = 1, COLORS.cyan
	settingsTitle.Font, settingsTitle.TextXAlignment = Enum.Font.SourceSansBold, Enum.TextXAlignment.Left
	settingsTitle.ZIndex = 21
	local themeLabel = text("TextLabel", ui.settingsPanel, "ThemeLabel", "Theme", 54)
	themeLabel.Position, themeLabel.Size = UDim2.fromOffset(14, 38), UDim2.fromOffset(54, 26)
	themeLabel.BackgroundTransparency, themeLabel.TextColor3 = 1, COLORS.muted
	themeLabel.TextXAlignment, themeLabel.ZIndex = Enum.TextXAlignment.Left, 21
	local function panelButton(name, caption, x, y, width, callback)
		local button = text("TextButton", ui.settingsPanel, name, caption, width)
		button.Position, button.Size = UDim2.fromOffset(x, y), UDim2.fromOffset(width, 26)
		button.AutoButtonColor, button.ZIndex = false, 21
		connect(ui, button.MouseButton1Click, callback)
		return button
	end
	ui.themeButtons.Graphite = panelButton("ThemeGraphite", "Graphite", 72, 38, 82, function()
		state.theme = "Graphite"
		applyTheme(state, ui)
		invoke(ui, "onThemeSet", "Graphite")
		if not ui.disposed then Timeline.redraw(state) end
	end)
	ui.themeButtons.Slate = panelButton("ThemeSlate", "Slate", 158, 38, 70, function()
		state.theme = "Slate"
		applyTheme(state, ui)
		invoke(ui, "onThemeSet", "Slate")
		if not ui.disposed then Timeline.redraw(state) end
	end)
	ui.themeButtons.Light = panelButton("ThemeLight", "Light", 232, 38, 70, function()
		state.theme = "Light"
		applyTheme(state, ui)
		invoke(ui, "onThemeSet", "Light")
		if not ui.disposed then Timeline.redraw(state) end
	end)
	local shortcutHelp = text("TextLabel", ui.settingsPanel, "ShortcutHelp",
		"Shortcuts\nR Rotate  •  M Move  •  Space Play  •  I Insert  •  Delete/Backspace Remove\n"
			.. "Ctrl+Z/Y Undo/Redo  •  Ctrl+C/V Copy/Paste\nCtrl+S Save  •  Ctrl+N New  •  Ctrl+E Export  •  G Settings", 320)
	shortcutHelp.Position, shortcutHelp.Size = UDim2.fromOffset(14, 72), UDim2.fromOffset(320, 92)
	shortcutHelp.BackgroundTransparency, shortcutHelp.TextColor3 = 1, COLORS.muted
	shortcutHelp.TextWrapped, shortcutHelp.TextXAlignment, shortcutHelp.TextYAlignment = true, Enum.TextXAlignment.Left, Enum.TextYAlignment.Top
	shortcutHelp.TextSize, shortcutHelp.ZIndex = 13, 21
	panelButton("CloseSettings", "Close", 268, 190, 68, function() toggleSettings(ui) end)

	ui.newPrompt = create("Frame", ui.root, { Name = "NewAnimationPrompt",
		Position = UDim2.new(0.5, -190, 0.5, -108), Size = UDim2.fromOffset(380, 216),
		BackgroundColor3 = COLORS.panel, BorderColor3 = COLORS.border, BorderSizePixel = 1,
		Visible = false, Active = true, ZIndex = 30 })
	local promptTitle = text("TextLabel", ui.newPrompt, "PromptTitle", "UNSAVED ANIMATION", 340)
	promptTitle.Position, promptTitle.Size = UDim2.fromOffset(18, 14), UDim2.fromOffset(340, 24)
	promptTitle.BackgroundTransparency, promptTitle.TextColor3 = 1, COLORS.cyan
	promptTitle.Font, promptTitle.TextXAlignment = Enum.Font.SourceSansBold, Enum.TextXAlignment.Left
	promptTitle.ZIndex = 31
	local promptMessage = text("TextLabel", ui.newPrompt, "PromptMessage",
		"Save changes before creating a new animation?", 340)
	promptMessage.Position, promptMessage.Size = UDim2.fromOffset(18, 54), UDim2.fromOffset(340, 48)
	promptMessage.BackgroundTransparency, promptMessage.TextColor3 = 1, COLORS.text
	promptMessage.TextWrapped, promptMessage.TextXAlignment = true, Enum.TextXAlignment.Left
	promptMessage.ZIndex = 31
	local function decideNewAnimation(decision)
		if ui.disposed then return end
		ui.newPrompt.Visible = false
		invoke(ui, "onNewAnimationDecision", decision)
	end
	local function promptButton(name, caption, x, callback)
		local button = text("TextButton", ui.newPrompt, name, caption, 104)
		button.Position, button.Size = UDim2.fromOffset(x, 148), UDim2.fromOffset(104, 30)
		button.AutoButtonColor, button.ZIndex = false, 31
		connect(ui, button.MouseButton1Click, callback)
	end
	promptButton("Save", "Save", 18, function() decideNewAnimation("save") end)
	promptButton("DontSave", "Don't Save", 132, function() decideNewAnimation("discard") end)
	promptButton("Cancel", "Cancel", 246, function() decideNewAnimation("cancel") end)
	connect(ui, ruler.InputBegan, function(input) beginScrub(ui, input) end)
	connect(ui, ui.canvas.InputBegan, function(input) beginScrub(ui, input) end)
	connect(ui, ui.canvas:GetPropertyChangedSignal("CanvasPosition"), function() renderVisible(ui) end)
	connect(ui, ui.canvas:GetPropertyChangedSignal("AbsoluteWindowSize"), function() Timeline.redraw(state) end)
	connect(ui, UserInputService.InputBegan, function(input, gameProcessed)
		keyboardShortcut(ui, input, gameProcessed)
	end)
	connect(ui, UserInputService.InputChanged, function(input)
		local gesture = ui.gesture
		if gesture and (input == gesture.input or (gesture.input.UserInputType ~= Enum.UserInputType.Touch
			and input.UserInputType == Enum.UserInputType.MouseMovement)) then moveGesture(ui, input.Position.X) end
	end)
	connect(ui, UserInputService.InputEnded, function(input)
		local gesture = ui.gesture
		if gesture and (input == gesture.input or (gesture.input.UserInputType ~= Enum.UserInputType.Touch
			and input.UserInputType == Enum.UserInputType.MouseButton1)) then
			moveGesture(ui, input.Position.X)
			finishGesture(ui, false)
		end
	end)
	connect(ui, UserInputService.WindowFocusReleased, function() finishGesture(ui, true) end)
	ui.refresh = function() refresh(ui) end
	local function dispose(destroying)
		if ui.disposed then return end
		if ui.gesture and ui.gesture.connection then releaseConnection(ui, ui.gesture.connection) end
		ui.disposed, ui.gesture = true, nil
		disconnect(ui.rowConnections, ui.connections)
		disconnect(ui.visibleConnections, ui.connections)
		disconnect(ui.connections)
		if ui.callbacks.refreshUi == ui.refresh then ui.callbacks.refreshUi = nil end
		if ui.callbacks.disposeUi == ui.dispose then ui.callbacks.disposeUi = nil end
		if state.ui == ui then state.ui = nil end
		if lastUi == ui then lastUi = nil end
		if not destroying then ui.root:Destroy() end
	end
	ui.dispose = function() dispose(false) end
	ui.callbacks.refreshUi, ui.callbacks.disposeUi = ui.refresh, ui.dispose
	connect(ui, ui.root.Destroying, function() dispose(true) end)
	Timeline.redraw(state)
	return ui.root
end

function Timeline.setSettingsOpen(state, isOpen)
	state.settingsOpen = not not isOpen
	local ui = state.ui
	if ui and not ui.disposed then setSettingsVisible(ui, state.settingsOpen) end
end

function Timeline.setTheme(state, theme)
	state.theme = PALETTES[theme] and theme or "Graphite"
	normalize(state)
	local ui = state.ui
	applyTheme(state, ui)
	if ui and not ui.disposed then Timeline.redraw(state) end
end

function Timeline.showNewAnimationPrompt(state)
	local ui = state.ui
	if ui and not ui.disposed and ui.newPrompt then ui.newPrompt.Visible = true end
end

function Timeline.hideNewAnimationPrompt(state)
	local ui = state.ui
	if ui and not ui.disposed and ui.newPrompt then ui.newPrompt.Visible = false end
end

function Timeline.setPlayhead(state, time)
	local minimum = finite(state.minTime, 0)
	local maximum = math.max(minimum, finite(state.maxTime, finite(state.duration, 5)))
	state.currentTime = math.clamp(finite(time, finite(state.currentTime, minimum)), minimum, maximum)
	local ui = state.ui
	if ui and not ui.disposed then
		invoke(ui, "onTimeChanged", state.currentTime)
		refresh(ui)
	end
end

function Timeline.setPlayButtonState(isPlaying)
	if lastUi and not lastUi.disposed then
		lastUi.buttons.play.Text = isPlaying and "Pause" or "Play"
		highlight(lastUi.buttons.play, isPlaying)
	end
end

return Timeline
