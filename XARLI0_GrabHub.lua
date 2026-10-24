local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer
if getgenv().SwiftKickTP then
	pcall(getgenv().SwiftKickTP.Destroy)
end
local Services = ReplicatedStorage:WaitForChild("Knit"):WaitForChild("Knit"):WaitForChild("Services")
local function effectsRemote(serviceName)
	return Services:WaitForChild(serviceName):WaitForChild("RE"):WaitForChild("Effects")
end
local ARM_WINDOW = 5
local State = {
	enabled = true,
	notify = true,
	keyToken = 0,
	profile = nil,
	holdSeconds = 1,
	holdConn = nil,
	tpDone = false,
	saved = nil,
	savedAt = 0,
	armedUntil = 0,
	returnPending = false,
	token = 0,
	selected = nil,
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
		pcall(function()
			game:GetService("StarterGui"):SetCore("SendNotification", { Title = title, Text = content, Duration = 3 })
		end)
	end
end
local function log(msg)
	table.insert(State.log, string.format("%.2f %s", os.clock(), msg))
end
local labelToModel = {}
local function collectTargets()
	local list = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LocalPlayer then
			local label = plr.DisplayName == plr.Name and plr.Name
				or string.format("%s (@%s)", plr.DisplayName, plr.Name)
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
	if State.onUseDone then
		State.onUseDone(State.profile)
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
	stopHold()
	if profile.maxDistance then
		local distance = (root.Position - targetRoot.Position).Magnitude
		if distance > profile.maxDistance then
			notify(profile.name, string.format("%s is %.0f studs away. The server only accepts short moves, get within %d studs.", target.Name, distance, profile.maxDistance))
			log(string.format("%s: target %.0f studs away (limit %d), not teleporting", profile.name, distance, profile.maxDistance))
			return
		end
	end
	State.returnPending = true
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
	local settle, rise = 0, 0
	if profile.underDepth and profile.underDepth > 0 then
		local underPos = targetPos - Vector3.new(0, profile.underDepth, 0)
		underCF = CFrame.lookAt(underPos, underPos + flat.Unit)
		pinCF = underCF
		settle = profile.settleTime or 0
		rise = profile.riseTime or 0
	end
	local riseStart
	root.CFrame = pinCF
	root.AssemblyLinearVelocity = Vector3.zero
	local function liveStand()
		if not (targetRoot and targetRoot.Parent) then return standCF end
		local p = targetRoot.Position - flat.Unit * (profile.standDistance or 0)
		return CFrame.lookAt(p, p + flat.Unit)
	end
	if State.pinConn then State.pinConn:Disconnect() end
	State.pinConn = RunService.Heartbeat:Connect(function()
		local r = getRoot()
		if r and State.returnPending then
			local cf = pinCF
			if not underCF then
				cf = liveStand()
			end
			if riseStart then
				local alpha = math.clamp((os.clock() - riseStart) / rise, 0, 1)
				alpha = 1 - (1 - alpha) * (1 - alpha)
				cf = underCF:Lerp(standCF, alpha)
			end
			r.CFrame = cf
			r.AssemblyLinearVelocity = Vector3.zero
		end
	end)
	State.releasePin = function()
		if State.pinConn then
			State.pinConn:Disconnect()
			State.pinConn = nil
		end
		local r = getRoot()
		if r and State.returnPending then
			r.CFrame = underCF and standCF or liveStand()
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
				pinCF = standCF
				log("rose up to " .. target.Name)
			end
		end)
	end
	local lead = settle + rise
	State.token += 1
	local token = State.token
	task.delay(profile.returnDelay + lead + (profile.preDelay or 0), function()
		if State.token == token and State.returnPending then
			returnToSaved()
		end
	end)
	return lead
end
local Profiles = {
	swift = {
		name = "Swift Kick",
		bind = { Value = "One" },
		oneShot = true,
		moveset = "Todo",
		remote = effectsRemote("SwiftKickService"),
		startStage = "Start",
		tpStages = { Dash = true, Grab = true },
		endStages = { Throw = true },
		returnDelay = 0.5,
		isMine = function(stage, a, mine)
			return stage == "Grab" or a == mine
		end,
	},
	cursed = {
		name = "Cursed Strikes",
		bind = { Value = "One" },
		oneShot = true,
		moveset = "Itadori",
		remote = effectsRemote("CursedStrikesService"),
		teleportFirst = true,
		toolName = "Cursed Strikes",
		preDelay = 0.5,
		holdWhileCasting = true,
		endStages = { Hit = true },
		endDelay = 0.1,
		returnDelay = 1.5,
		isMine = function(stage, a, mine, b)
			if stage == "Hit" then return b == true end
			return a == mine
		end,
	},
	rapid = {
		name = "Rapid Punches",
		comingSoon = true,
		moveset = "Gojo",
		remote = effectsRemote("RapidPunchesService"),
		teleportFirst = true,
		toolName = "Rapid Punches",
		underDepth = 6,
		settleTime = 5,
		riseTime = 0.6,
		preDelay = 0,
		holdWhileCasting = true,
		maxDistance = nil,
		standDistance = 3.5,
		endStages = { Hit = true, FinalHit = true, BlackFlashHit = true },
		endDelay = 0.05,
		returnDelay = 2.5,
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
local function startKeyTrigger(profile)
	stopHold()
	State.profile = profile
	State.tpDone = false
	savePosition()
	State.keyToken += 1
	local token = State.keyToken
	local char = LocalPlayer.Character
	local tool = char and char:FindFirstChild("Moveset") and char.Moveset:FindFirstChild(profile.toolName)
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
			stopHold()
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
				returnToSaved()
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
		cast()
		return
	end
	savePosition()
	local lead = teleportToTarget(profile)
	if not State.returnPending then
		cast()
		return
	end
	local wait = (lead or 0) + profile.preDelay
	log(string.format("%s: teleported first, casting in %.2fs", profile.name, wait))
	task.delay(wait, function()
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
			return
		end
		local args = table.pack(...)
		task.spawn(function()
			startTeleportFirst(profile, function()
				State.bypass = true
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
local Effects = workspace:WaitForChild("Effects")
local DOOR_DEPTHS = { 10.5, 9, 7.5, 6 }
local DOOR_REACH = 12
local Door = { enabled = false, alive = true, pin = nil, saved = nil, tries = setmetatable({}, { __mode = "k" }) }
local function doorRoot()
	local c = LocalPlayer.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function liveDoors()
	local list = {}
	for _, m in ipairs(Effects:GetChildren()) do
		if m.Name == "HalloweenDoor" then
			local pp = m:FindFirstChildWhichIsA("ProximityPrompt", true)
			if pp and pp.Enabled and pp.Parent and pp.Parent:IsA("Attachment") then
				table.insert(list, { model = m, prompt = pp })
			end
		end
	end
	return list
end
local function doorStanding(d)
	return d.model.Parent == Effects and d.prompt.Parent ~= nil and d.prompt.Enabled
end
local function nearestDoor(list)
	local root = doorRoot()
	local best, bestDist
	for _, d in ipairs(list) do
		local dist = root and (d.prompt.Parent.WorldPosition - root.Position).Magnitude or 0
		if not best or dist < bestDist then
			best, bestDist = d, dist
		end
	end
	return best
end
local function headParts()
	local c = LocalPlayer.Character
	if not c then return end
	return c, c:FindFirstChildOfClass("Humanoid"), c:FindFirstChild("Head"),
		c:FindFirstChild("UpperTorso") or c:FindFirstChild("Torso")
end
local function sinkHead()
	if Door.neck then return end
	local _, hum, head, torso = headParts()
	if not (head and torso and hum) then return end
	local neck = head:FindFirstChild("Neck") or torso:FindFirstChild("Neck")
	if not neck then return end
	hum.RequiresNeck = false
	Door.neck = { clone = neck:Clone(), parent = neck.Parent, hum = hum }
	neck:Destroy()
	log("head: detached, sinking it into the torso")
end
local function restoreHead()
	local n = Door.neck
	if not n then return end
	Door.neck = nil
	local _, _, head, torso = headParts()
	if head and torso and n.parent and n.parent.Parent then
		head.CFrame = torso.CFrame * CFrame.new(0, torso.Size.Y / 2 + head.Size.Y / 2, 0)
		n.clone.Parent = n.parent
	end
	if n.hum then n.hum.RequiresNeck = true end
	log("head: put back on the neck")
end
local function stopDoorPin(keepHead)
	if not keepHead then restoreHead() end
	if Door.pin then
		Door.pin:Disconnect()
		Door.pin = nil
	end
	if Door.noclip then
		Door.noclip:Disconnect()
		Door.noclip = nil
		local c = LocalPlayer.Character
		if c then
			for _, part in ipairs(c:GetDescendants()) do
				if part:IsA("BasePart") then
					part.LocalTransparencyModifier = 0
				end
			end
		end
	end
end
local function pinUnderDoor(d)
	stopDoorPin(true)
	local depth = DOOR_DEPTHS[math.min((Door.tries[d.prompt] or 0) + 1, #DOOR_DEPTHS)]
	local cf = CFrame.new(d.prompt.Parent.WorldPosition - Vector3.new(0, depth, 0))
	Door.cf = cf
	Door.pin = RunService.Heartbeat:Connect(function()
		local r = doorRoot()
		if r then
			r.CFrame = cf
			r.AssemblyLinearVelocity = Vector3.zero
		end
		local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
		local animator = hum and hum:FindFirstChildOfClass("Animator")
		if animator then
			for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
				track:Stop(0)
			end
		end
	end)
	Door.noclip = RunService.Stepped:Connect(function()
		local c = LocalPlayer.Character
		if not c then return end
		for _, part in ipairs(c:GetDescendants()) do
			if part:IsA("BasePart") and part.CanCollide then
				part.CanCollide = false
			end
		end
		local r = doorRoot()
		if r then
			r.CFrame = cf
			r.AssemblyLinearVelocity = Vector3.zero
		end
		if Door.neck then
			local _, _, head, torso = headParts()
			if head and torso then
				head.CFrame = torso.CFrame
				head.AssemblyLinearVelocity = Vector3.zero
			end
		end
	end)
	local r = doorRoot()
	if r then r.CFrame = cf end
	if Door.hideHead then sinkHead() end
end
local function takeDoor(d)
	local pp = d.prompt
	pp.MaxActivationDistance = DOOR_REACH
	pp.RequiresLineOfSight = false
	local tries = Door.tries[pp] or 0
	Door.tries[pp] = tries + 1
	pp.HoldDuration = tries == 0 and 0 or 5
	local triggered = false
	local conn = pp.Triggered:Connect(function(who)
		if who == LocalPlayer then triggered = true end
	end)
	task.wait(0.15)
	pcall(function() pp:InputHoldBegin() end)
	if fireproximityprompt then pcall(fireproximityprompt, pp) end
	local start = os.clock()
	while Door.alive and Door.enabled and doorStanding(d) and not triggered do
		if os.clock() - start > pp.HoldDuration + 1.5 then break end
		task.wait(0.05)
	end
	pcall(function() pp:InputHoldEnd() end)
	conn:Disconnect()
	return triggered
end
local function doorLoop()
	while Door.alive do
		task.wait(0.15)
		if not Door.enabled or State.returnPending then
			if Door.pin and not Door.enabled then stopDoorPin() end
			continue
		end
		local doors = liveDoors()
		if #doors == 0 then
			if Door.pin then
				stopDoorPin()
				local r = doorRoot()
				if r and Door.saved then
					r.CFrame = Door.saved
					r.AssemblyLinearVelocity = Vector3.zero
				end
				Door.saved = nil
				log("doors: none left, returned")
			end
			continue
		end
		local r = doorRoot()
		if not r then continue end
		if not Door.saved then
			Door.saved = r.CFrame
			log("doors: " .. #doors .. " spawned")
		end
		local d = nearestDoor(doors)
		pinUnderDoor(d)
		for _ = 1, 5 do
			task.wait(0.15)
			local rr = doorRoot()
			if rr and Door.cf and (rr.Position - Door.cf.Position).Magnitude < 2 then break end
			log("doors: teleport did not land, restarting it")
			pinUnderDoor(d)
		end
		local got = takeDoor(d)
		log(got and "doors: took the candy" or (doorStanding(d) and "doors: not taken, retrying" or "doors: someone else took it"))
	end
	stopDoorPin()
end
task.spawn(doorLoop)
local Timer = { enabled = true, lastStart = nil, interval = 30, open = false, label = nil }
local function timerText()
	local doors = #liveDoors()
	if doors > 0 then
		return string.format("Doors open: %d left", doors)
	end
	if not Timer.lastStart then
		return "Waiting for the first event..."
	end
	local left = math.max(0, math.ceil(Timer.lastStart + Timer.interval - os.clock()))
	if left > 0 then
		return string.format("Next doors in about %ds", left)
	end
	return "Doors due any moment..."
end
connect(Effects.ChildAdded, function(child)
	if child.Name ~= "HalloweenDoor" or Timer.open then return end
	Timer.open = true
	local now = os.clock()
	if Timer.lastStart then
		local gap = now - Timer.lastStart
		if gap > 10 and gap < 180 then
			Timer.interval = gap
		end
	end
	Timer.lastStart = now
	log("event: doors appeared")
end)
task.spawn(function()
	while Door.alive do
		task.wait(1)
		if Timer.open and #liveDoors() == 0 then
			Timer.open = false
		end
		if Timer.enabled and Timer.label then
			pcall(function() Timer.label:UpdateLabel(timerText()) end)
		end
	end
end)
local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/GhostDuckyy/UI-Libraries/3b0bcba89893baa65d36b12b33e70e93ebc8b122/Kavo/source.lua"))()
local CoreGui = game:GetService("CoreGui")
local before = {}
for _, c in ipairs(CoreGui:GetChildren()) do before[c] = true end
local Window = Library.CreateLib("XARLI0's Grab Hub", "DarkTheme")
local KavoGui
for _, c in ipairs(CoreGui:GetChildren()) do
	if not before[c] and c:IsA("ScreenGui") then KavoGui = c end
end
local MainTab = Window:NewTab("Main")
local TargetTab = Window:NewTab("Target")
local GrabSection = MainTab:NewSection("Grabs (switch off after one use)")
local SwiftToggle = GrabSection:NewToggle("Swift Kick", "Todo, key 1", function(v)
	Profiles.swift.enabled = v
	log("menu: Swift Kick enabled=" .. tostring(v))
end)
local CursedToggle = GrabSection:NewToggle("Cursed Strikes", "Vessel, key 1", function(v)
	Profiles.cursed.enabled = v
	log("menu: Cursed Strikes enabled=" .. tostring(v))
end)
GrabSection:NewLabel("Rapid Punches: coming soon")
Profiles.swift.enabled = false
Profiles.cursed.enabled = false
State.onUseDone = function(profile)
	if not (profile and profile.oneShot) then return end
	profile.enabled = false
	local toggle = (profile == Profiles.swift and SwiftToggle) or (profile == Profiles.cursed and CursedToggle) or nil
	if toggle then
		pcall(function() toggle:UpdateToggle(nil, false) end)
	end
	log(profile.name .. ": switched off after use")
end
do
	local function switchOf(name)
		if not KavoGui then return end
		for _, d in ipairs(KavoGui:GetDescendants()) do
			if d.Name == "toggleElement" then
				local label = d:FindFirstChild("togName")
				if label and label.Text == name then
					return d:FindFirstChild("toggleEnabled")
				end
			end
		end
	end
	local pairsToWatch = {
		{ profile = Profiles.swift, toggle = SwiftToggle, img = switchOf("Swift Kick"), bad = 0 },
		{ profile = Profiles.cursed, toggle = CursedToggle, img = switchOf("Cursed Strikes"), bad = 0 },
	}
	task.spawn(function()
		while Door.alive do
			task.wait(0.3)
			for _, w in ipairs(pairsToWatch) do
				if w.img then
					local shownOn = w.img.ImageTransparency < 0.5
					if shownOn ~= w.profile.enabled then
						w.bad += 1
						if w.bad >= 3 then
							w.bad = 0
							log(w.profile.name .. ": switch out of step, resyncing to " .. tostring(w.profile.enabled))
							pcall(function() w.toggle:UpdateToggle(nil, w.profile.enabled) end)
						end
					else
						w.bad = 0
					end
				end
			end
		end
	end)
end
local HalloweenSection = MainTab:NewSection("Halloween")
local DoorToggle = HalloweenSection:NewToggle("Door hopper", "Off until you switch it on: hides under a door, takes the candy, then the next door", function(v)
	Door.enabled = v
	if not v then
		stopDoorPin()
		local r = doorRoot()
		if r and Door.saved then
			r.CFrame = Door.saved
			Door.saved = nil
		end
	end
	log("menu: Door hopper enabled=" .. tostring(v))
end)
HalloweenSection:NewToggle("Sink head (test)", "While hiding, take the head off its neck and hold it inside the torso. Unproven whether others see it", function(v)
	Door.hideHead = v
	if not v then restoreHead() end
	log("menu: Sink head enabled=" .. tostring(v))
end)
Timer.label = HalloweenSection:NewLabel(timerText())
local TimerToggle = HalloweenSection:NewToggle("Event timer", "Counts down to the next door event", function(v)
	Timer.enabled = v
	if not v and Timer.label then
		pcall(function() Timer.label:UpdateLabel("Event timer is off") end)
	end
end)
TimerToggle:UpdateToggle(nil, true)
local MenuSection = MainTab:NewSection("Menu")
MenuSection:NewLabel("RightShift hides or shows this menu")
MenuSection:NewButton("Destroy script", "Removes the menu and all listeners", function()
	getgenv().SwiftKickTP.Destroy()
end)
local TargetSection = TargetTab:NewSection("Target")
local TargetDropdown
local SelectedLabel = TargetSection:NewLabel("Selected: nobody")
local function showSelected()
	local m = State.selected
	SelectedLabel:UpdateLabel("Selected: " .. (m and m.Name or "nobody"))
end
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
		State.selected = modelOf(selectEntry)
		showSelected()
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
TargetSection:NewTextBox("Search player", "Type a name, typos are fine. Empty shows everyone.", function(text)
	runSearch(text or "")
end)
do
	local initial = collectTargets()
	local labels = {}
	for _, entry in ipairs(initial) do
		labelToModel[entry.label] = entry
		table.insert(labels, entry.label)
	end
	if #labels == 0 then labels = { "(nobody found)" } end
	TargetDropdown = TargetSection:NewDropdown("Target", "Every player and dummy in the server", labels, function(label)
		local entry = labelToModel[label]
		State.selected = entry and modelOf(entry) or nil
		showSelected()
	end)
	if initial[1] then
		State.selected = modelOf(initial[1])
		showSelected()
	end
end
task.defer(function()
	local box
	if KavoGui then
		for _, d in ipairs(KavoGui:GetDescendants()) do
			if d:IsA("TextBox") then
				box = d
				break
			end
		end
	end
	if box then
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
TargetSection:NewButton("Refresh list", "Re-scan players and dummies", function()
	runSearch("", true)
	notify("Targets", "List refreshed.")
end)
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
connect(UserInputService.InputBegan, function(input)
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	if UserInputService:GetFocusedTextBox() then return end
	if input.KeyCode == Enum.KeyCode.RightShift then
		pcall(function() Library:ToggleUI() end)
		return
	end
	if not State.enabled then return end
	local profile = profileForCurrentMoveset()
	if profile and profile.enabled and profile.bind and input.KeyCode.Name == profile.bind.Value then
		if State.returnPending then return end
		if profile.teleportFirst then
			return
		elseif profile.trigger == "key" then
			startKeyTrigger(profile)
		else
			State.profile = profile
			savePosition()
		end
	end
end)
getgenv().SwiftKickTP = {
	State = State,
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
		State.keyToken += 1
		toolController.UseTool = originalUseTool
		for _, c in ipairs(connections) do
			pcall(function() c:Disconnect() end)
		end
		table.clear(connections)
		Door.alive = false
		stopDoorPin()
		if KavoGui then pcall(function() KavoGui:Destroy() end) end
		getgenv().SwiftKickTP = nil
	end,
}
notify("XARLI0's Grab Hub", "Loaded. Press RightShift to hide or show the menu.")
