-- Grab TP | WindUI
-- Press an ability key (Swift Kick, Rapid Punches): your position is saved. When that ability's grab
-- or hit stage comes up you are teleported to the selected player/dummy, then sent back.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer

if getgenv().SwiftKickTP then
	pcall(getgenv().SwiftKickTP.Destroy)
end

local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

local Services = ReplicatedStorage:WaitForChild("Knit"):WaitForChild("Knit"):WaitForChild("Services")

local function effectsRemote(serviceName)
	return Services:WaitForChild(serviceName):WaitForChild("RE"):WaitForChild("Effects")
end

local ARM_WINDOW = 5 -- seconds a saved position stays valid for a grab

local State = {
	enabled = true,
	notify = true,
	keyToken = 0, -- invalidates a pending key-triggered teleport when the key is pressed again
	profile = nil, -- profile of the ability currently in progress
	holdSeconds = 1, -- how long to pin the character at the saved position after the return
	holdConn = nil,
	tpDone = false,
	saved = nil,
	savedAt = 0,
	armedUntil = 0,
	returnPending = false,
	token = 0,
	selected = nil, -- model of the chosen target
	log = {},
}

local connections = {}
local function connect(signal, fn)
	local c = signal:Connect(fn)
	table.insert(connections, c)
	return c
end

local function notify(title, content)
	if State.notify then
		WindUI:Notify({ Title = title, Content = content, Duration = 3, Icon = "zap" })
	end
end

local function log(msg)
	table.insert(State.log, string.format("%.2f %s", os.clock(), msg))
end

------------------------------------------------------------------ targets

local labelToModel = {}

local function collectTargets()
	local list = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LocalPlayer then
			local label = plr.DisplayName == plr.Name and plr.Name
				or string.format("%s (＠%s)", plr.DisplayName, plr.Name)
			table.insert(list, { label = label, names = { plr.Name:lower(), plr.DisplayName:lower() }, plr = plr })
		end
	end
	table.sort(list, function(a, b) return a.label:lower() < b.label:lower() end)

	local npcs = {}
	local folder = workspace:FindFirstChild("Characters")
	if folder then
		for _, model in ipairs(folder:GetChildren()) do
			if model:IsA("Model") and not Players:GetPlayerFromCharacter(model) and model:FindFirstChild("HumanoidRootPart") then
				table.insert(npcs, model)
			end
		end
	end
	for i, model in ipairs(npcs) do
		local label = #npcs == 1 and model.Name .. " (NPC)" or string.format("%s #%d (NPC)", model.Name, i)
		table.insert(list, { label = label, names = { model.Name:lower(), "dummy", "npc" }, model = model })
	end
	return list
end

local function modelOf(entry)
	if entry.plr then
		return entry.plr.Character
	end
	return entry.model
end

------------------------------------------------------------------ fuzzy search

local function normalize(s)
	return (tostring(s):lower():gsub("[^%w]", ""))
end

local function editDistance(a, b)
	local la, lb = #a, #b
	if la == 0 then return lb end
	if lb == 0 then return la end
	local prev, cur = {}, {}
	for j = 0, lb do prev[j] = j end
	for i = 1, la do
		cur[0] = i
		local ca = a:byte(i)
		for j = 1, lb do
			local cost = (ca == b:byte(j)) and 0 or 1
			cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
		end
		prev, cur = cur, prev
	end
	return prev[lb]
end

local function isSubsequence(q, s)
	local qi = 1
	for i = 1, #s do
		if qi <= #q and s:byte(i) == q:byte(qi) then
			qi += 1
		end
	end
	return qi > #q
end

local function scoreName(q, name)
	name = normalize(name)
	if name == "" then return 0 end
	if name == q then return 100 end
	if name:sub(1, #q) == q then return 90 - (#name - #q) * 0.5 end
	if name:find(q, 1, true) then return 75 - (#name - #q) * 0.3 end
	if #q >= 2 and isSubsequence(q, name) then return 55 end
	-- typo tolerance: compare against the same-length prefix as well as the whole name
	local best = 0
	for _, candidate in ipairs({ name, name:sub(1, #q + 1) }) do
		local d = editDistance(q, candidate)
		local ratio = 1 - d / math.max(#q, #candidate)
		if ratio >= 0.5 then
			best = math.max(best, 20 + ratio * 30)
		end
	end
	return best
end

local function rank(query)
	local q = normalize(query)
	local entries = collectTargets()
	if q == "" then
		return entries, nil, entries[1]
	end
	local scored = {}
	for _, entry in ipairs(entries) do
		local s = 0
		for _, n in ipairs(entry.names) do
			s = math.max(s, scoreName(q, n))
		end
		if s >= 25 then
			table.insert(scored, { entry = entry, score = s })
		end
	end
	table.sort(scored, function(a, b) return a.score > b.score end)
	local out = {}
	for _, item in ipairs(scored) do table.insert(out, item.entry) end
	local best = scored[1]
	local corrected = best and best.score < 75 and best.entry or nil
	return out, corrected, best and best.entry
end

------------------------------------------------------------------ teleport logic

local function getRoot()
	local char = LocalPlayer.Character
	return char and char:FindFirstChild("HumanoidRootPart"), char
end

local function savePosition()
	local root = getRoot()
	if not root then return end
	State.saved = root.CFrame
	State.savedAt = os.clock()
	State.armedUntil = os.clock() + ARM_WINDOW
	log("saved position")
end

local function stopHold()
	if State.holdConn then
		State.holdConn:Disconnect()
		State.holdConn = nil
	end
end

-- pin the character at the saved spot for a moment so the grab and throw physics cannot fling it
local function holdAt(cf)
	stopHold()
	if State.holdSeconds <= 0 then return end
	local untilTime = os.clock() + State.holdSeconds
	State.holdConn = RunService.Heartbeat:Connect(function()
		local r = getRoot()
		if not r or os.clock() >= untilTime then
			stopHold()
			return
		end
		r.CFrame = cf
		r.AssemblyLinearVelocity = Vector3.zero
		r.AssemblyAngularVelocity = Vector3.zero
	end)
end

local function returnToSaved()
	State.token += 1
	if not State.returnPending then return end
	State.returnPending = false
	State.armedUntil = 0
	if State.pinConn then
		State.pinConn:Disconnect()
		State.pinConn = nil
	end
	local root = getRoot()
	if root and State.saved then
		root.CFrame = State.saved
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		holdAt(State.saved)
		log("returned to saved position, holding for " .. State.holdSeconds .. "s")
	end
end

local function teleportToTarget(profile)
	local root = getRoot()
	local target = State.selected
	local targetRoot = target and target.Parent and target:FindFirstChild("HumanoidRootPart")
	if not root or not targetRoot then
		notify(profile.name, "No valid target selected, staying put.")
		log("grab: no valid target")
		return
	end
	stopHold() -- a new grab cancels any hold from the previous one
	-- some abilities are checked against the server's idea of where we are, and the server reverts big
	-- teleports, so a far target never gets hit. Those profiles set maxDistance and skip far targets.
	if profile.maxDistance then
		local distance = (root.Position - targetRoot.Position).Magnitude
		if distance > profile.maxDistance then
			notify(profile.name, string.format("%s is %.0f studs away. The server only accepts short moves, get within %d studs.", target.Name, distance, profile.maxDistance))
			log(string.format("%s: target %.0f studs away (limit %d), not teleporting", profile.name, distance, profile.maxDistance))
			return
		end
	end
	State.returnPending = true

	-- stand on the side we came from, facing along the line toward the target. standDistance 0 puts us
	-- exactly on them (Swift Kick's big hit box covers that); punches need the target in front of us.
	local targetPos = targetRoot.Position
	local fromPos = State.saved and State.saved.Position or root.Position
	local flat = Vector3.new(targetPos.X - fromPos.X, 0, targetPos.Z - fromPos.Z)
	if flat.Magnitude < 0.1 then
		local look = targetRoot.CFrame.LookVector
		flat = Vector3.new(look.X, 0, look.Z)
	end
	local standPos = targetPos - flat.Unit * (profile.standDistance or 0)
	local standCF = CFrame.lookAt(standPos, standPos + flat.Unit)
	local pinCF = standCF
	local underCF
	local settle, rise = 0, 0 -- seconds waiting under the target, then seconds spent moving up to the real spot
	if profile.underDepth and profile.underDepth > 0 then
		-- start directly under the target and wait there so the game registers where we are, then rise
		local underPos = targetPos - Vector3.new(0, profile.underDepth, 0)
		underCF = CFrame.lookAt(underPos, underPos + flat.Unit)
		pinCF = underCF
		settle = profile.settleTime or 0
		rise = profile.riseTime or 0
	end
	local riseStart -- set when the tween up to the real spot begins

	root.CFrame = pinCF
	root.AssemblyLinearVelocity = Vector3.zero
	-- hold the spot every frame so the dash velocity cannot carry us off before the hit lands. While rising
	-- the held spot slides from under the target to the real spot (a tween, not a jump).
	if State.pinConn then State.pinConn:Disconnect() end
	State.pinConn = RunService.Heartbeat:Connect(function()
		local r = getRoot()
		if r and State.returnPending then
			local cf = pinCF
			if riseStart then
				local alpha = math.clamp((os.clock() - riseStart) / rise, 0, 1)
				alpha = 1 - (1 - alpha) * (1 - alpha) -- ease out
				cf = underCF:Lerp(standCF, alpha)
			end
			r.CFrame = cf
			r.AssemblyLinearVelocity = Vector3.zero
		end
	end)

	-- Let go of the character: put it on the real spot one last time and stop holding it, so nothing we do
	-- to the character (pinning it, zeroing its velocity) is in effect while the move is cast and plays out.
	State.releasePin = function()
		if State.pinConn then
			State.pinConn:Disconnect()
			State.pinConn = nil
		end
		local r = getRoot()
		if r and State.returnPending then
			r.CFrame = standCF
		end
	end
	log("teleported " .. (underCF and "under " or "onto ") .. target.Name)
	if underCF then
		task.delay(settle, function()
			if not State.returnPending then return end
			if rise > 0 then
				riseStart = os.clock()
				log(string.format("rising to %s over %.2fs", target.Name, rise))
			else
				pinCF = standCF -- the pin loop above now holds the real spot
				log("rose up to " .. target.Name)
			end
		end)
	end
	local lead = settle + rise -- seconds until we are standing at the real spot

	State.token += 1
	local token = State.token
	-- the timed return must outlast the wait under, the rise and any wait before the cast
	task.delay(profile.returnDelay + lead + (profile.preDelay or 0), function()
		if State.token == token and State.returnPending then
			returnToSaved()
		end
	end)
	return lead
end

------------------------------------------------------------------ profiles

-- One profile per grab ability. Stage names and argument layouts come from each ability's Effects remote.
-- Styles:
--   stage-triggered (Swift Kick): the ability sends a start event and a grab stage. startStage saves the
--     position if the key press was missed, and the first of tpStages teleports us onto the target.
--   teleport-first (Rapid Punches, teleportFirst = true): the cast is held back, we teleport onto the target,
--     wait preDelay, then cast (see the UseTool wrapper below).
--   key-triggered (trigger = "key", currently unused): teleport tpDelay after the key press.
-- endStages are the events that mean the ability landed or was thrown; we return when one arrives.
local Profiles = {
	swift = {
		name = "Swift Kick",
		bind = { Value = "One" }, -- fixed: Swift Kick is on key 1
		moveset = "Todo",
		remote = effectsRemote("SwiftKickService"),
		startStage = "Start",
		tpStages = { Dash = true, Grab = true }, -- Dash decides the grab; Grab is a fallback
		endStages = { Throw = true },
		returnDelay = 0.5, -- seconds on the target before the timed return
		-- Swift Kick: Start/Dash/Throw carry our character first; Grab carries only the victim
		isMine = function(stage, a, mine)
			return stage == "Grab" or a == mine
		end,
	},
	cursed = {
		name = "Cursed Strikes",
		bind = { Value = "One" }, -- fixed: Cursed Strikes is on key 1
		moveset = "Itadori", -- Vessel / Yuji
		remote = effectsRemote("CursedStrikesService"),
		-- The lunge grabs about 0.6s after the cast, decided almost at once (the grab lands 0.03s after the Dash),
		-- so the teleport has to come first: the cast is held back, we teleport onto the target, wait, then cast.
		-- Tested: this grabbed a target 141 studs away; teleporting at the Dash (too late) missed.
		teleportFirst = true,
		toolName = "Cursed Strikes", -- entry in the character's Moveset; ReadyAt tells us if it is on cooldown
		preDelay = 0.5, -- seconds to wait on the target before the move is cast
		holdWhileCasting = true, -- stay pinned at the target through the cast until the grab lands
		endStages = { Hit = true }, -- Hit(victim, true) is the grab; the later Hits are the combo
		endDelay = 0.1, -- seconds after the grab lands before returning
		returnDelay = 1.5, -- longest time on the target after the cast if no grab ever lands
		-- Hit carries the victim with true marking the grab itself; ignore the combo hits
		isMine = function(stage, a, mine, b)
			if stage == "Hit" then return b == true end
			return a == mine
		end,
	},
	rapid = {
		name = "Rapid Punches",
		comingSoon = true, -- switched off: the server only lets this move hit from close range
		moveset = "Gojo",
		remote = effectsRemote("RapidPunchesService"),
		teleportFirst = true, -- hold the cast, teleport onto the target, then cast
		toolName = "Rapid Punches", -- entry in the character's Moveset; ReadyAt tells us if it is on cooldown
		underDepth = 6, -- start this many studs directly under the target, wait, then rise (0 = go straight to them)
		settleTime = 5, -- seconds to wait under the target so the game registers the position
		riseTime = 0.6, -- seconds the tween up to the target takes (0 = instant jump)
		preDelay = 0, -- seconds to wait after rising before casting (0 = cast the moment the tween ends)
		holdWhileCasting = true, -- keep pinned at the target through the cast; releasing lets the server pull us home first
		maxDistance = nil, -- unlimited range; set a number to skip targets farther than that
		standDistance = 3.5, -- studs in front of the target so it sits inside the punch's hit area
		endStages = { Hit = true, FinalHit = true, BlackFlashHit = true }, -- first hit that lands
		endDelay = 0.05, -- seconds after the hit lands before returning
		returnDelay = 2.5, -- longest time spent at the target after rising, if no hit ever lands
		-- Hit/FinalHit only carry the victim; BlackFlashHit carries the attacker first
		isMine = function(stage, a, mine)
			if stage == "BlackFlashHit" then return a == mine end
			return true
		end,
	},
}

local function movesetOf(char)
	return char and char:GetAttribute("Moveset")
end

local function profileForCurrentMoveset()
	local moveset = movesetOf(LocalPlayer.Character)
	for _, profile in pairs(Profiles) do
		if profile.moveset == moveset then
			return profile
		end
	end
end

-- key-triggered abilities: called when the ability key is pressed
local function startKeyTrigger(profile)
	stopHold()
	State.profile = profile
	State.tpDone = false
	savePosition()
	State.keyToken += 1
	local token = State.keyToken

	local char = LocalPlayer.Character
	local tool = char and char:FindFirstChild("Moveset") and char.Moveset:FindFirstChild(profile.toolName)

	-- The move's LastUse/ReadyAt only update after it has run, so they cannot confirm a start. ReadyAt is
	-- still useful to skip a press that is on cooldown: nothing would start, so there is nothing to teleport for.
	local readyAt = tool and tool:GetAttribute("ReadyAt") or 0
	if workspace:GetServerTimeNow() < readyAt then
		log(profile.name .. ": on cooldown, not teleporting")
		return
	end

	task.delay(profile.tpDelay, function()
		if State.keyToken == token and State.profile == profile and not State.tpDone and not State.returnPending then
			State.tpDone = true
			teleportToTarget(profile)
		end
	end)
end

local function handleStage(profile, stage, a, b)
	if not State.enabled or not profile.enabled then return end
	local mine = LocalPlayer.Character
	if not mine or movesetOf(mine) ~= profile.moveset then return end

	if stage == profile.startStage then
		if profile.isMine(stage, a, mine, b) then
			stopHold() -- a new grab cancels the previous hold so the move is not blocked
			State.profile = profile
			if os.clock() - State.savedAt > 1.5 then
				savePosition()
			end
			State.armedUntil = os.clock() + ARM_WINDOW
			State.tpDone = false
		end
	elseif profile.tpStages and profile.tpStages[stage] then
		if State.profile == profile and not State.tpDone and os.clock() < State.armedUntil and State.saved
			and profile.isMine(stage, a, mine, b) then
			State.tpDone = true
			teleportToTarget(profile)
		end
	elseif profile.endStages[stage] then
		if State.profile == profile and State.returnPending and profile.isMine(stage, a, mine, b) then
			local delay = profile.endDelay or 0
			if delay <= 0 then
				returnToSaved() -- also a safety net if the timed return has not fired yet
			else
				State.token += 1
				local token = State.token
				task.delay(delay, function()
					if State.token == token and State.returnPending then
						returnToSaved()
					end
				end)
			end
		end
	end
end

for _, profile in pairs(Profiles) do
	profile.enabled = not profile.comingSoon
	connect(profile.remote.OnClientEvent, function(stage, a, b)
		handleStage(profile, stage, a, b)
	end)
end

-- Teleport-first abilities: a key press makes the game call ToolController:UseTool(tool, "Activated"), which
-- casts the move. For these profiles we hold that cast back, teleport onto the target, wait a moment, and
-- then cast. This swaps one method on the game's ToolController table (no global hook, so input is
-- untouched) and is restored on destroy.
local toolController = require(LocalPlayer.PlayerScripts.Controllers.Character.ToolController)
local originalUseTool = toolController.UseTool

local function startTeleportFirst(profile, cast)
	stopHold()
	State.profile = profile
	State.tpDone = true

	local char = LocalPlayer.Character
	local tool = char and char:FindFirstChild("Moveset") and char.Moveset:FindFirstChild(profile.toolName)
	local readyAt = tool and tool:GetAttribute("ReadyAt") or 0
	if workspace:GetServerTimeNow() < readyAt then
		log(profile.name .. ": on cooldown, casting normally")
		cast() -- nothing would start, so let the game handle the press as usual
		return
	end

	savePosition()
	local lead = teleportToTarget(profile)
	if not State.returnPending then
		cast() -- no valid target (or too far for the limit): just cast where we stand
		return
	end
	local wait = (lead or 0) + profile.preDelay -- time under the target (if any), then the wait at the real spot
	log(string.format("%s: teleported first, casting in %.2fs", profile.name, wait))
	task.delay(wait, function()
		-- let go of the character first, so the move is cast with nothing holding or pinning it
		-- (unless holdWhileCasting is on, which keeps the position pinned until you return)
		if State.releasePin and not profile.holdWhileCasting then
			State.releasePin()
		end
		cast()
	end)
end

toolController.UseTool = function(self, tool, action, ...)
	local profile = State.enabled and profileForCurrentMoveset() or nil
	if profile and profile.enabled and profile.teleportFirst and not State.bypass and action == "Activated"
		and typeof(tool) == "Instance" and tool.Name == profile.toolName then
		if State.returnPending then
			return -- a teleport is already in progress, swallow the repeated press
		end
		local args = table.pack(...)
		task.spawn(function()
			startTeleportFirst(profile, function()
				State.bypass = true -- our own cast must not be intercepted again
				local ok, err = pcall(originalUseTool, self, tool, action, table.unpack(args, 1, args.n))
				State.bypass = false
				if not ok then
					log("cast failed: " .. tostring(err))
				end
			end)
		end)
		return
	end
	return originalUseTool(self, tool, action, ...)
end

------------------------------------------------------------------ UI

local Window = WindUI:CreateWindow({
	Title = "XARLI0's Grab Hub",
	Author = "swift kick + cursed strikes",
	Icon = "zap",
	Folder = "SwiftKickTP",
	Size = UDim2.fromOffset(560, 470),
	MinSize = Vector2.new(420, 340),
	SideBarWidth = 130,
	Theme = "Dark",
	Transparent = true,
	Resizable = true,
	ToggleKey = Enum.KeyCode.RightShift,
	OpenButton = {
		Title = "XARLI0's Grab Hub",
		Icon = "zap",
		CornerRadius = UDim.new(0, 16),
		StrokeThickness = 2,
		Color = ColorSequence.new(Color3.fromHex("7C3AED"), Color3.fromHex("06B6D4")),
		OnlyMobile = false,
		Enabled = true,
		Draggable = true,
	},
})

local MainTab = Window:Tab({ Title = "Main", Icon = "zap" })
local TargetTab = Window:Tab({ Title = "Target", Icon = "crosshair" })

-- Every setting below is fixed to the values I tested; there is nothing to tune. Each ability only
-- reacts while you are on its character.
MainTab:Toggle({
	Title = "Swift Kick",
	Desc = "Todo, key 1",
	Value = true,
	Callback = function(v)
		Profiles.swift.enabled = v
		log("menu: Swift Kick enabled=" .. tostring(v))
	end,
})

MainTab:Toggle({
	Title = "Cursed Strikes",
	Desc = "Vessel, key 1",
	Value = true,
	Callback = function(v)
		Profiles.cursed.enabled = v
		log("menu: Cursed Strikes enabled=" .. tostring(v))
	end,
})

MainTab:Paragraph({
	Title = "Rapid Punches",
	Desc = "Coming soon.",
})

MainTab:Button({
	Title = "Destroy script",
	Icon = "trash-2",
	Callback = function()
		getgenv().SwiftKickTP.Destroy()
	end,
})

------------------------------------------------------------------ target tab

local TargetDropdown
local SearchInput

local function applyList(entries, selectEntry)
	labelToModel = {}
	local labels = {}
	for _, entry in ipairs(entries) do
		labelToModel[entry.label] = entry
		table.insert(labels, entry.label)
	end
	if #labels == 0 then
		labels = { "(nobody found)" }
	end
	TargetDropdown:Refresh(labels)
	if selectEntry then
		TargetDropdown:Select(selectEntry.label)
		State.selected = modelOf(selectEntry)
	end
end

local function runSearch(text, quiet)
	local entries, corrected, best = rank(text)
	if #entries == 0 then
		entries = collectTargets()
		if not quiet then
			notify("Search", 'No match for "' .. text .. '", showing everyone.')
		end
		best = nil
	end
	applyList(entries, best)
	if corrected and not quiet then
		notify("Did you mean", corrected.label .. "?")
	end
end

SearchInput = TargetTab:Input({
	Title = "Search player",
	Desc = "Type a name, typos are fine. Empty shows everyone.",
	Placeholder = "Search...",
	Value = "",
	Callback = function(text)
		runSearch(text or "")
	end,
})

do
	local initial = collectTargets()
	local labels = {}
	for _, entry in ipairs(initial) do
		labelToModel[entry.label] = entry
		table.insert(labels, entry.label)
	end
	if #labels == 0 then labels = { "(nobody found)" } end
	TargetDropdown = TargetTab:Dropdown({
		Title = "Target",
		Desc = "Every player and dummy in the server",
		Values = labels,
		Value = labels[1],
		SearchBarEnabled = true,
		Callback = function(label)
			local entry = labelToModel[label]
			State.selected = entry and modelOf(entry) or nil
		end,
	})
	if initial[1] then
		State.selected = modelOf(initial[1])
	end
end

-- live "as you type" suggestions when the input's TextBox can be found
task.defer(function()
	local ok, box = pcall(function()
		return SearchInput.InputFrame.UIElements.Main:FindFirstChildWhichIsA("TextBox", true)
	end)
	if ok and box then
		local last = ""
		connect(box:GetPropertyChangedSignal("Text"), function()
			local text = box.Text
			if text == last then return end
			last = text
			task.delay(0.15, function()
				if box.Text == text then
					runSearch(text, true)
				end
			end)
		end)
	end
end)

TargetTab:Button({
	Title = "Refresh list",
	Desc = "Re-scan players and dummies",
	Icon = "refresh-cw",
	Callback = function()
		runSearch("", true)
		notify("Targets", "List refreshed.")
	end,
})

local refreshQueued = false
local function queueRefresh()
	if refreshQueued then return end
	refreshQueued = true
	task.delay(0.5, function()
		refreshQueued = false
		runSearch("", true)
	end)
end

connect(Players.PlayerAdded, queueRefresh)
connect(Players.PlayerRemoving, queueRefresh)
local charFolder = workspace:FindFirstChild("Characters")
if charFolder then
	connect(charFolder.ChildAdded, queueRefresh)
	connect(charFolder.ChildRemoved, queueRefresh)
end

------------------------------------------------------------------ save-on-key

connect(UserInputService.InputBegan, function(input)
	if not State.enabled then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	if UserInputService:GetFocusedTextBox() then return end
	-- the ability key saves your position and tells the matching profile it is the one in progress
	local profile = profileForCurrentMoveset()
	if profile and not profile.enabled and not profile.comingSoon and profile.bind and input.KeyCode.Name == profile.bind.Value then
		notify(profile.name, "Switched off in the menu, turn it on in the Main tab.")
	end
	if profile and profile.enabled and profile.bind and input.KeyCode.Name == profile.bind.Value then
		-- a teleport is already in progress: repeated presses (spamming the key) must not re-save the
		-- position at the target
		if State.returnPending then return end
		if profile.teleportFirst then
			return -- handled by the UseTool wrapper, which sees the game's own cast
		elseif profile.trigger == "key" then
			startKeyTrigger(profile)
		else
			State.profile = profile
			savePosition()
		end
	end
end)

------------------------------------------------------------------ teardown

getgenv().SwiftKickTP = {
	State = State,
	-- used to test the return, hold and key-triggered teleport without a real key press
	Debug = {
		ReturnToSaved = returnToSaved,
		StartKeyTrigger = startKeyTrigger,
		HandleStage = handleStage,
		Profiles = Profiles,
	},
	Destroy = function()
		if State.pinConn then
			pcall(function() State.pinConn:Disconnect() end)
		end
		if State.holdConn then
			pcall(function() State.holdConn:Disconnect() end)
		end
		State.keyToken += 1 -- cancel any pending key-triggered teleport
		toolController.UseTool = originalUseTool -- put the game's own cast function back
		for _, c in ipairs(connections) do
			pcall(function() c:Disconnect() end)
		end
		table.clear(connections)
		pcall(function() Window:Destroy() end)
		getgenv().SwiftKickTP = nil
	end,
}

Window:SelectTab(1)
notify("XARLI0's Grab Hub", "Loaded. Press RightShift to hide or show the menu.")
