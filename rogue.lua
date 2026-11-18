--// Spectate (menu player list) — Matcha port (v13)
--// v13: fixes "Out of local registers" (Lua 5.1 allows max 200 locals per function): sections are
--//      now scoped in do-blocks so they stop counting once finished. No behaviour changes vs v12.
local ranOk = pcall(function()

SP_GEN = (SP_GEN or 0) + 1
local GEN = SP_GEN
local dead, hopped = false, false
local function alive() return GEN == SP_GEN and not dead end

local Players, RunService, UserInputService, LocalPlayer
pcall(function()
	Players          = game:GetService("Players")
	RunService       = game:GetService("RunService")
	UserInputService = game:GetService("UserInputService")
	LocalPlayer      = Players.LocalPlayer
end)

--==============================================================
-- CONFIG
--==============================================================
local OFFSETS_URL   = "https://offsets.imtheo.lol/offsets.json"
local CACHE_FILE    = "sp_offsets_cache.json"
local CAMTYPE_FILE  = "sp_camtype_ok.txt"
local DEFAULTS = { subj = 176, camtype = 288, campos = 228, camrot = 192, io = 232, mpos = 188 }
local GAME_CAM_MAX_DIST = 100
local ROW_H, PANEL_W = 18, 430
local RESET_WINDOW = 3
local OVERLAY_X, OVERLAY_Y = 20, 200      -- starting position (drag the header to move it)
local REVEAL_HIDDEN = false               -- true = unhide hidden players while in the menu
local MENU_METHOD   = "cf"                -- "cf" = CFrame follow, "subj" = CameraSubject
local FOLLOW_DIST   = 12                  -- starting menu follow distance
local MIN_DIST, MAX_DIST = 2, 200

-- camera feel
local LOOK_SENS     = 0.0065              -- radians per pixel (raise = faster turning)
local KEY_TURN      = 2.4                 -- Left/Right/Up/Down arrows, radians per second
local KEY_ZOOM      = 1.4                 -- I/O, PageUp/PageDown, =/-  (zoom factor per second)
local WHEEL_ZOOM    = 0.85                -- distance multiplier per wheel notch
local ZOOM_SMOOTH   = 14                  -- higher = snappier zoom
local MOUSE_RECENTER = true               -- warps the cursor to screen centre if you drag into an edge

-- flicker vs lag: each extra writer fights the game's camera harder but costs speed
local DRIVER_THREADS = 1                  -- tight-loop camera writers (RenderStepped + Heartbeat also write)

-- menu camera script (see notes in the reply). Names must match EXACTLY what the console prints.
local PRINT_SCRIPT_CANDIDATES = true      -- prints scripts that look camera/menu related, once, on load
local CAM_KEYWORDS = { "camera", "cam", "menu", "spawn", "title", "lobby", "select", "intro" }
local DISABLE_MENU_SCRIPTS = {}           -- e.g. { "MenuCamera" }  (disabled while spectating from the menu)

local LBLUE = Color3.fromRGB(120, 200, 255)   -- spectated player
local GREY  = Color3.fromRGB(130, 130, 130)   -- NOT spawned in
local WHITE, GOLD = Color3.fromRGB(240, 240, 240), Color3.fromRGB(255, 214, 81)

local lower, find, gsub, len = string.lower, string.find, string.gsub, string.len
local abs, sqrt, sin, cos, floor = math.abs, math.sqrt, math.sin, math.cos, math.floor

--==============================================================
-- HELPERS
--==============================================================
local function setp(obj, name, value)
	return pcall(function() obj[name] = value end)
end

local function setTextSize(t, n)
	if not setp(t, "Size", n) then setp(t, "FontSize", n) end
end

local function newText(size, zindex)
	local t
	pcall(function()
		t = Drawing.new("Text")
		setp(t, "Outline", true)
		setp(t, "Center", false)
		setp(t, "ZIndex", zindex or 2)
		setTextSize(t, size)
		setp(t, "Visible", false)
	end)
	return t
end

local seenMsg = {}
local function logOnce(msg)
	pcall(function()
		if not seenMsg[msg] then
			seenMsg[msg] = true
			pcall(print, "[SPEC] " .. msg)
			pcall(notify, msg, "Spectate", 6)
		end
	end)
end

local function addrOf(inst)
	local ok, a = pcall(function() return inst.Address end)
	if ok then return a end
	return nil
end

local function attr(p, name)
	local ok, v = pcall(function() return p:GetAttribute(name) end)
	return ok and v or nil
end

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

-- Drawing property cache: only touch a Drawing when a value really changed
local setPos, setSize, setVis, setTxt, setCol
do
local oc = setmetatable({}, { __mode = "k" })
local function ocache(obj)
	local c = oc[obj]
	if not c then c = {}; oc[obj] = c end
	return c
end
function setPos(obj, x, y)
	if not obj then return end
	local c = ocache(obj)
	if c.x ~= x or c.y ~= y then c.x, c.y = x, y; setp(obj, "Position", Vector2.new(x, y)) end
end
function setSize(obj, w, h)
	if not obj then return end
	local c = ocache(obj)
	if c.w ~= w or c.h ~= h then c.w, c.h = w, h; setp(obj, "Size", Vector2.new(w, h)) end
end
function setVis(obj, v)
	if not obj then return end
	local c = ocache(obj)
	if c.v ~= v then c.v = v; setp(obj, "Visible", v) end
end
function setTxt(obj, s)
	if not obj then return end
	local c = ocache(obj)
	if c.t ~= s then c.t = s; setp(obj, "Text", s) end
end
function setCol(obj, col)
	if not obj then return end
	local c = ocache(obj)
	if c.c ~= col then c.c = col; setp(obj, "Color", col) end
end
end

--==============================================================
-- SESSION (server hop: never touch the old session's memory)
--==============================================================
local function sessionInfo()
	local job, lp, dm
	pcall(function() job = game.JobId end)
	pcall(function() lp = LocalPlayer.Address end)
	pcall(function() dm = game.Address end)
	if type(job) ~= "string" or job == "" then job = nil end
	return { job = job, lp = lp, dm = dm }
end
local session0 = sessionInfo()

local function checkSession()
	local res = false
	local ok = pcall(function()
		if dead then res = true return end
		local s = sessionInfo()
		if (s.job and session0.job and s.job ~= session0.job)
			or (s.lp and session0.lp and s.lp ~= session0.lp)
			or (s.dm and session0.dm and s.dm ~= session0.dm) then
			dead, hopped = true, true
			res = true
		end
	end)
	if not ok then return false end
	return res
end

--==============================================================
-- SHARED STATE
--==============================================================
local CAM_CUSTOM, CAM_SCRIPTABLE = 5, 6

local stopSpectating, hardReset
local Spectating, specHumAddr, specBadSince, specHrp = nil, nil, nil, nil
local specMode = nil                       -- "subj" (CameraSubject) or "cf" (CFrame follow)
local overriding, origSubject, origIsOwn = false, nil, false
local camTypeOrig, camTypeWritten, camCheckAt = nil, nil, nil
local dirty = false
local resetUntil = 0
local inMenu = false
local SpecStatus = "idle"
local cfPropBad, cfErrCount, cfState = false, 0, "-"
local camAddr, camObj = nil, nil

-- overlay UI state
local uiHidden = false
local ovX, ovY = OVERLAY_X, OVERLAY_Y
local dragging, dragOX, dragOY = false, 0, 0

-- menu orbit camera state
local camYaw, camPitch, camDist, camDistTarget = 0, 0.3, FOLLOW_DIST, FOLLOW_DIST
local wheelAcc = 0

-- per-frame input snapshot
local inp = { active = false, m1 = false, m2 = false }

local Data, Order = {}, {}
local nameMap = {}

--==============================================================
-- OFFSETS (updated once, when the script runs)
--==============================================================
local offs = { subj = DEFAULTS.subj, camtype = DEFAULTS.camtype, campos = DEFAULTS.campos,
	camrot = DEFAULTS.camrot, io = DEFAULTS.io, mpos = DEFAULTS.mpos }
local OffInfo = { version = "built-in", dumped = "?", source = "built-in", status = "not checked" }
local offsetTrusted, camTypeBad, camTypeVerified = false, false, nil

pcall(function()
	if isfile(CAMTYPE_FILE) then camTypeVerified = tonumber(string.match(readfile(CAMTYPE_FILE), "^(%d+)")) end
end)

do
local function parseOffset(body, block, key)
	local ok, r = pcall(function()
		local v = string.match(body, '"' .. block .. '"%s*:%s*{[^}]-"' .. key .. '"%s*:%s*(%d+)')
		return v and tonumber(v) or nil
	end)
	return ok and r or nil
end

local function applyBody(body, source)
	local ok, res = pcall(function()
		local s = parseOffset(body, "Camera", "CameraSubject")
		if not s or s < 16 or s > 1024 then return false end
		local n = {
			subj    = s,
			camtype = parseOffset(body, "Camera", "CameraType") or DEFAULTS.camtype,
			campos  = parseOffset(body, "Camera", "Position") or DEFAULTS.campos,
			camrot  = parseOffset(body, "Camera", "Rotation") or DEFAULTS.camrot,
			io      = parseOffset(body, "MouseService", "InputObject") or DEFAULTS.io,
			mpos    = parseOffset(body, "MouseService", "MousePosition") or DEFAULTS.mpos,
		}
		local changed = false
		for k, v in pairs(n) do
			if offs[k] ~= v then changed = true end
		end
		if changed and Spectating then pcall(stopSpectating) end
		for k, v in pairs(n) do offs[k] = v end
		if changed then offsetTrusted, camTypeBad = false, false end
		OffInfo.version = string.match(body, '"Roblox Version"%s*:%s*"([^"]+)"') or "?"
		OffInfo.dumped  = string.match(body, '"Dumped At"%s*:%s*"([^"]+)"') or "?"
		OffInfo.source  = source
		return true
	end)
	return ok and res == true
end

local function refreshOffsets()
	pcall(function()
		OffInfo.status = "fetching..."
		local ok, body = pcall(httpget, OFFSETS_URL)
		if ok and type(body) == "string" and body:find('"Offsets"') then
			if applyBody(body, "live") then
				pcall(writefile, CACHE_FILE, body)
				OffInfo.status = "updated on script run"
				return
			end
		end
		local okc, cached = pcall(function() if isfile(CACHE_FILE) then return readfile(CACHE_FILE) end end)
		if okc and type(cached) == "string" and applyBody(cached, "cache") then
			OffInfo.status = "fetch failed - using cache"
			return
		end
		OffInfo.status = "fetch failed - using built-in"
	end)
end

pcall(refreshOffsets)
end

--==============================================================
-- LEADERBOARD NAME LOGIC (from LeaderboardClient)
--==============================================================
local function formatName(first, uber, last, rank, gender)
	local ok, s = pcall(function()
		local title = ""
		if rank == "Owner" then
			title = (gender == "Female") and "Lady" or "Lord"
			if first == "Ratriel" then title = "Pontiff" end
		end
		local parts = {}
		if title ~= "" then parts[#parts + 1] = title end
		if first and first ~= "" and first ~= " " then parts[#parts + 1] = first end
		if last and last ~= "" then parts[#parts + 1] = last end
		local r = table.concat(parts, " ")
		if uber and uber ~= "" then r = r .. ", " .. uber end
		return r
	end)
	return ok and s or ""
end

local function lessThan(a, b)
	local ok, r = pcall(function()
		local la, lb = a.last or "", b.last or ""
		if (la ~= "") ~= (lb ~= "") then return la ~= "" end
		if la ~= lb then return la < lb end
		local fa, fb = a.first or "???", b.first or "???"
		if fa ~= fb then return fa < fb end
		return a.player.Name < b.player.Name
	end)
	return ok and r or false
end

local function simplify(s)
	local ok, r = pcall(function()
		s = lower(tostring(s))
		s = gsub(s, "<[^>]+>", "")
		s = gsub(s, "[^%w]", "")
		return s
	end)
	return ok and r or ""
end

local function cleanText(s)
	local ok, r = pcall(function()
		s = tostring(s)
		s = gsub(s, "<[^>]+>", "")
		s = gsub(s, "^%s+", "")
		s = gsub(s, "%s+$", "")
		return s
	end)
	return ok and r or ""
end

local computeAliases
do
local JUNK_NAMES = {
	bodycolors = true, head = true, torso = true, uppertorso = true, lowertorso = true,
	humanoidrootpart = true, humanoid = true, animate = true, characterhandler = true,
	handler = true, health = true, shirt = true, pants = true, hat = true, accessory = true,
}

function computeAliases(char)
	local keys = {}
	pcall(function()
		for _, c in ipairs(char:GetChildren()) do
			local cn = ""
			pcall(function() cn = c.ClassName end)
			if cn == "Model" then
				local k = simplify(c.Name)
				if k ~= "" and not JUNK_NAMES[k] then keys[#keys + 1] = k end
			end
		end
	end)
	return keys
end
end

--==============================================================
-- MENU CAMERA SCRIPT: finder + disabler
--==============================================================
local disableMenuScripts, restoreMenuScripts
do
local function readName(i) return i.Name end
local function readParent(i) return i.Parent end
local function readDisabled(s) return s.Disabled end
local function writeDisabled(s, v) s.Disabled = v end
local function pathOf(inst)
	local parts, cur = {}, inst
	for _ = 1, 14 do
		if not cur then break end
		local ok, nm = pcall(readName, cur)
		if not ok then break end
		table.insert(parts, 1, tostring(nm))
		local okP, par = pcall(readParent, cur)
		if not okP then break end
		cur = par
	end
	return table.concat(parts, ".")
end

local function printScriptCandidates()
	pcall(function()
		local ok, scripts = pcall(getscripts)
		if not ok or type(scripts) ~= "table" then
			pcall(print, "[SPEC] getscripts() failed - cannot list scripts")
			return
		end
		pcall(print, "[SPEC] ---- camera/menu-looking scripts (put the exact Name in DISABLE_MENU_SCRIPTS) ----")
		local shown = 0
		for _, s in ipairs(scripts) do
			if shown >= 80 then break end
			pcall(function()
				local nm = lower(tostring(s.Name))
				for _, k in ipairs(CAM_KEYWORDS) do
					if find(nm, k, 1, true) then
						local cn = ""
						pcall(function() cn = s.ClassName end)
						pcall(print, string.format("[SPEC]  Name=%s  Class=%s  Path=%s", tostring(s.Name), cn, pathOf(s)))
						shown = shown + 1
						break
					end
				end
			end)
		end
		pcall(print, "[SPEC] ---- " .. shown .. " listed ----")
	end)
end

local disabledScripts = {}
function disableMenuScripts()
	pcall(function()
		if #DISABLE_MENU_SCRIPTS == 0 or next(disabledScripts) ~= nil then return end
		local set = {}
		for _, n in ipairs(DISABLE_MENU_SCRIPTS) do set[n] = true end
		local ok, scripts = pcall(getscripts)
		if not ok or type(scripts) ~= "table" then return end
		for _, s in ipairs(scripts) do
			local okN, nm = pcall(readName, s)
			if okN and set[nm] then
				local okD, prev = pcall(readDisabled, s)
				if pcall(writeDisabled, s, true) then
					disabledScripts[s] = (okD and prev) or false
				end
			end
		end
	end)
end

function restoreMenuScripts()
	pcall(function()
		for s, prev in pairs(disabledScripts) do
			pcall(writeDisabled, s, prev)
			disabledScripts[s] = nil
		end
	end)
end

if PRINT_SCRIPT_CANDIDATES then pcall(printScriptCandidates) end
end

--==============================================================
-- PLAYER SAMPLING (attributes + name map) — polling, no events
--==============================================================
local function sample()
	local reveal = REVEAL_HIDDEN == true and inMenu
	local seen, nm = {}, {}

	for _, p in ipairs(Players:GetPlayers()) do
		pcall(function()
			seen[p] = true
			local d = Data[p]
			if not d then
				d = { player = p, char = nil, revealed = false, aliases = {}, aliasTries = 0, spawned = false }
				Data[p] = d
			end

			d.first, d.uber, d.last = attr(p, "FirstName"), attr(p, "UberTitle"), attr(p, "LastName")
			d.rank, d.gender = attr(p, "HouseRank"), attr(p, "Gender")
			d.prestige, d.edict = attr(p, "Prestige"), attr(p, "MaxEdict")

			local hid = attr(p, "Hidden")
			if reveal and p ~= LocalPlayer then
				if hid == true then
					d.revealed = true
					pcall(function() p:SetAttribute("Hidden", false) end)
				end
			elseif d.revealed then
				pcall(function() p:SetAttribute("Hidden", true) end)
				d.revealed = false
			end
			d.hidden = (hid == true) or d.revealed
			d.color = d.edict and GOLD or WHITE

			local char = p.Character
			if char ~= d.char then
				d.char = char
				d.aliases, d.aliasTries = {}, 0
			end
			if char and #d.aliases == 0 and d.aliasTries < 6 then
				d.aliasTries = d.aliasTries + 1
				d.aliases = computeAliases(char)
			end

			-- spawned in = has a living humanoid
			local sp = false
			pcall(function()
				local hum = char and char:FindFirstChild("Humanoid")
				sp = hum ~= nil and (hum.Health or 0) > 0
			end)
			d.spawned = sp

			local function add(s)
				local k = simplify(s)
				if k ~= "" then nm[k] = p end
			end
			add(p.Name)
			local okD, dn = pcall(function() return p.DisplayName end)
			if okD and type(dn) == "string" then add(dn) end
			add(formatName(d.first, d.uber, d.last, d.rank, d.gender))
			add(formatName(d.first, nil, d.last, d.rank, d.gender))
			add(formatName(d.first, nil, d.last, nil, d.gender))
			if d.first and d.first ~= "" then add(d.first) end
			for _, a in ipairs(d.aliases) do nm[a] = p end
		end)
	end
	nameMap = nm

	pcall(function()
		for p in pairs(Data) do
			if not seen[p] then Data[p] = nil end
		end
	end)

	pcall(function()
		local order = {}
		for _, d in pairs(Data) do order[#order + 1] = d end
		table.sort(order, lessThan)
		Order = order
	end)
end

task.spawn(function()
	while alive() do
		pcall(function()
			if not checkSession() then pcall(sample) end
		end)
		pcall(wait, 1.0)
	end
end)

--==============================================================
-- CAMERA HELPERS
--==============================================================
local lastHP, lastMyAddr = nil, nil
local runeDecals = {}

local function readCamObj() return workspace.CurrentCamera end

local function refreshCam()
	local ok, c = pcall(readCamObj)
	if ok and c then
		camObj = c
		local okA, a = pcall(function() return c.Address end)
		if okA and a then camAddr = a end
	end
	return camAddr
end

local function myHumanoid()
	local ok, h = pcall(function()
		local c = LocalPlayer.Character
		return c and c:FindFirstChild("Humanoid")
	end)
	return ok and h or nil
end

local function rdPtr(addr)
	local ok, v = pcall(memory_read, "uintptr_t", addr)
	if ok then return tonumber(v) end
end

local function markCamTypeVerified()
	pcall(function()
		if offs.camtype and camTypeVerified ~= offs.camtype then
			camTypeVerified = offs.camtype
			pcall(writefile, CAMTYPE_FILE, tostring(camTypeVerified))
		end
	end)
end

local function readCamPos(ca)
	local ok, x, y, z = pcall(function()
		local p = workspace.CurrentCamera.CFrame.Position
		return p.X, p.Y, p.Z
	end)
	if ok and type(x) == "number" then return x, y, z end
	if ca and offs.campos then
		local ok2, a, b, c = pcall(function()
			return memory_read("float", ca + offs.campos), memory_read("float", ca + offs.campos + 4),
				memory_read("float", ca + offs.campos + 8)
		end)
		if ok2 and type(a) == "number" and a == a and abs(a) < 1e6 and abs(b) < 1e6 and abs(c) < 1e6 then
			return a, b, c
		end
	end
end

local function setCamType(ca, val)
	local ok, res = pcall(function()
		local off = offs.camtype
		if not off then return false end
		local okR, cur = pcall(memory_read, "int", ca + off)
		if not okR or type(cur) ~= "number" or cur < 0 or cur > 7 then return false end
		if cur == val then return false end
		if camTypeOrig == nil then camTypeOrig = cur end
		pcall(memory_write, "int", ca + off, val)
		camTypeWritten = val
		return true
	end)
	return ok and res == true
end

local function restoreCamType()
	pcall(function()
		local ca, off = camAddr, offs.camtype
		if camTypeOrig ~= nil and camTypeWritten ~= nil and ca and off then
			local okR, cur = pcall(memory_read, "int", ca + off)
			if okR and cur == camTypeWritten and cur ~= camTypeOrig then
				pcall(memory_write, "int", ca + off, camTypeOrig)
			end
		end
	end)
	camTypeOrig, camTypeWritten = nil, nil
end

local function collectRunes(char)
	if not char then return end
	pcall(function()
		for _, d in ipairs(char:GetDescendants()) do
			local ok, cn, par = pcall(function() return d.ClassName, d.Parent.Name end)
			if ok and cn == "Decal" and par and string.match(par, "Slot%d+") then
				local a = addrOf(d) or d
				if not runeDecals[a] then
					local okT, t = pcall(function() return d.Transparency end)
					if okT and t == 1 then runeDecals[a] = d end
				end
			end
		end
	end)
end

local function runeTick()
	pcall(function()
		for a, d in pairs(runeDecals) do
			local ok, t = pcall(function() return d.Transparency end)
			if not ok then runeDecals[a] = nil
			elseif t ~= 1 then pcall(function() d.Transparency = 1 end) end
		end
	end)
end

local function menuUsesCF()
	return MENU_METHOD ~= "subj"
end

--==============================================================
-- STOP / RESET
--==============================================================
stopSpectating = function(reason)
	pcall(function()
		local mode = specMode
		if overriding then
			overriding = false
			if mode == "subj" then
				pcall(function()
					local ca = refreshCam()
					if not (ca and offs.subj) then return end
					local mh = myHumanoid()
					local ma = mh and addrOf(mh)
					if reason == "menu" then
						memory_write("uintptr_t", ca + offs.subj, 0)
					elseif ma then
						memory_write("uintptr_t", ca + offs.subj, ma)
					elseif origSubject and not origIsOwn then
						local cur = rdPtr(ca + offs.subj)
						if cur == tonumber(specHumAddr) then memory_write("uintptr_t", ca + offs.subj, origSubject) end
					end
				end)
			end
		end
		pcall(restoreCamType)
		pcall(restoreMenuScripts)
	end)
	camCheckAt = nil
	runeDecals = {}
	Spectating, specHumAddr, specBadSince, specHrp, specMode = nil, nil, nil, nil, nil
	cfState = "-"
	SpecStatus = "idle"
end

hardReset = function(kind)
	pcall(function()
		if not (dirty or overriding or Spectating) then return end
		pcall(stopSpectating, kind)
		dirty = false
		if kind == "spawn" then resetUntil = tick() + RESET_WINDOW end
		SpecStatus = "idle (camera reset)"
	end)
end

local function resetTick(now)
	pcall(function()
		if now > resetUntil then return end
		local ca = camAddr
		if not ca then return end
		local mh = myHumanoid()
		local ma = mh and addrOf(mh)
		if ma and offs.subj then
			local cur = rdPtr(ca + offs.subj)
			if cur ~= tonumber(ma) then pcall(memory_write, "uintptr_t", ca + offs.subj, ma) end
		end
		if offs.camtype then
			local okR, cur = pcall(memory_read, "int", ca + offs.camtype)
			if okR and type(cur) == "number" and cur >= 0 and cur <= 7 and cur ~= CAM_CUSTOM then
				pcall(memory_write, "int", ca + offs.camtype, CAM_CUSTOM)
			end
		end
	end)
end

--==============================================================
-- START SPECTATING
--==============================================================
local function followCheck(now)
	pcall(function()
		if not camCheckAt or now < camCheckAt or not specHrp or specMode ~= "subj" then return end
		camCheckAt = nil
		local okT, tp = pcall(function() return specHrp.Position end)
		local cx, cy, cz = readCamPos(camAddr)
		if not (okT and tp and cx) then return end
		if (cx - tp.X) ^ 2 + (cy - tp.Y) ^ 2 + (cz - tp.Z) ^ 2 < GAME_CAM_MAX_DIST ^ 2 then
			markCamTypeVerified()
			SpecStatus = "following " .. (Spectating and Spectating.Name or "?")
		elseif inMenu then
			logOnce("Menu CameraSubject mode didn't follow - the menu camera script is overriding it (see DISABLE_MENU_SCRIPTS)")
			pcall(stopSpectating)
		else
			camTypeBad = true
			restoreCamType()
			logOnce("CameraType write didn't make the camera follow - not using that offset again")
		end
	end)
end

local function startSpectating(player)
	local ok, res = pcall(function()
		if not player or player == LocalPlayer then stopSpectating() return false end
		local char = player.Character
		local ca = refreshCam()
		if not ca then logOnce("Camera.Address is nil - cannot spectate") return false end

		local mode = (inMenu and menuUsesCF()) and "cf" or "subj"
		if overriding and specMode ~= mode then stopSpectating() end

		if inMenu then disableMenuScripts() end

		-- MENU: CFrame follow (CameraType becomes Scriptable, the subject is left alone)
		if mode == "cf" then
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if not hrp then logOnce("Target has no HumanoidRootPart - can't spectate") return false end
			if not overriding then
				camTypeOrig, camTypeWritten = nil, nil
				setCamType(ca, CAM_SCRIPTABLE)
				camYaw, camPitch, camDist, camDistTarget = 0, 0.3, FOLLOW_DIST, FOLLOW_DIST
				wheelAcc = 0
			end
			overriding = true
			Spectating, specHumAddr, specBadSince, specHrp, specMode = player, nil, nil, hrp, "cf"
			cfPropBad, cfErrCount, cfState = false, 0, "starting"
			dirty = true
			SpecStatus = "following " .. player.Name .. " (menu)"
			return true
		end

		-- SPAWNED IN (or menu CameraSubject method)
		local hum = char and char:FindFirstChild("Humanoid")
		local ha = hum and addrOf(hum)
		if not ha then logOnce("Target has no Humanoid.Address - can't spectate") return false end

		if not overriding then
			local cur = rdPtr(ca + offs.subj)
			local mine = myHumanoid()
			local myAddr = mine and addrOf(mine)
			if myAddr and cur == tonumber(myAddr) then offsetTrusted = true end
			if not offsetTrusted then
				local plausible = (not myAddr) and cur ~= nil and (cur == 0 or cur > 65536)
				if not plausible then
					logOnce(string.format("Subject check failed (offset 0x%X) - not writing", offs.subj))
					return false
				end
			end
			origSubject = cur
			origIsOwn = (myAddr ~= nil and cur == tonumber(myAddr))
			camTypeOrig, camTypeWritten = nil, nil
		end

		local wrote = false
		if not camTypeBad then wrote = setCamType(ca, CAM_CUSTOM) end
		local okW = pcall(memory_write, "uintptr_t", ca + offs.subj, ha)
		if not okW then logOnce("memory_write failed - enable Unsafe LuaU Execution") return false end
		overriding = true
		Spectating, specHumAddr, specBadSince, specMode = player, ha, nil, "subj"
		specHrp = char:FindFirstChild("HumanoidRootPart")
		if inMenu or (wrote and camTypeVerified ~= offs.camtype) then camCheckAt = tick() + 1.5 end
		dirty = true
		collectRunes(char)
		collectRunes(LocalPlayer.Character)
		SpecStatus = "spectating " .. player.Name
		return true
	end)
	return ok and res == true
end

local function toggleSpectate(player)
	pcall(function()
		if not player then return end
		if Spectating == player or player == LocalPlayer then stopSpectating() else startSpectating(player) end
	end)
end

--==============================================================
-- MENU CFRAME FOLLOW (orbit camera) — kept as lean as possible
-- Orbit angles are changed only in updateOrbit(); this just applies them.
--==============================================================
local cfTick
do
local function readTarget()
	local p = specHrp.Position
	return p.X, p.Y, p.Z
end

local function enforceScriptable()
	local cur = memory_read("int", camAddr + offs.camtype)
	if type(cur) == "number" and cur >= 0 and cur <= 7 and cur ~= CAM_SCRIPTABLE then
		memory_write("int", camAddr + offs.camtype, CAM_SCRIPTABLE)
	end
end

local function writeCamProp(px, py, pz, fx, fy, fz)
	camObj.CFrame = CFrame.new(Vector3.new(px, py, pz), Vector3.new(fx, fy, fz))
end

local function writeCamMem(px, py, pz, fx, fy, fz)
	local dx, dy, dz = fx - px, fy - py, fz - pz
	local l = sqrt(dx * dx + dy * dy + dz * dz)
	if l <= 1e-4 then return end
	dx, dy, dz = dx / l, dy / l, dz / l
	local rx, rz = -dz, dx
	local rl = sqrt(rx * rx + rz * rz)
	if rl < 1e-4 then rx, rz = 1, 0 else rx, rz = rx / rl, rz / rl end
	local ux, uy, uz = -rz * dy, rz * dx - rx * dz, rx * dy
	local r = camAddr + offs.camrot
	local m = { rx, ux, -dx, 0, uy, -dy, rz, uz, -dz }
	for i = 1, 9 do memory_write("float", r + (i - 1) * 4, m[i]) end
	memory_write("float", camAddr + offs.campos, px)
	memory_write("float", camAddr + offs.campos + 4, py)
	memory_write("float", camAddr + offs.campos + 8, pz)
end

local cfCalls = 0
local function cfFollow()
	if not (Spectating and specMode == "cf" and specHrp and camAddr) then return end
	local ok, tx, ty, tz = pcall(readTarget)
	if not ok or type(tx) ~= "number" then return end

	cfCalls = cfCalls + 1
	if offs.camtype and cfCalls % 15 == 0 then pcall(enforceScriptable) end

	local fx, fy, fz = tx, ty + 1.5, tz
	local cp = cos(camPitch)
	local px = fx + camDist * sin(camYaw) * cp
	local py = fy + camDist * sin(camPitch)
	local pz = fz + camDist * cos(camYaw) * cp

	if not cfPropBad and camObj then
		if pcall(writeCamProp, px, py, pz, fx, fy, fz) then
			cfErrCount = 0
		else
			cfErrCount = cfErrCount + 1
			if cfErrCount >= 5 then cfPropBad = true end
		end
	elseif cfPropBad and offs.camrot and offs.campos then
		pcall(writeCamMem, px, py, pz, fx, fy, fz)
	end
end

function cfTick()
	if alive() and Spectating and specMode == "cf" and inMenu then pcall(cfFollow) end
end
end

-- extra tight-loop writers
for _ = 1, DRIVER_THREADS do
	pcall(function()
		task.spawn(function()
			while alive() do
				pcall(cfTick)
				pcall(wait)
			end
		end)
	end)
end

--==============================================================
-- SPECTATE UPKEEP
--==============================================================
local function pinSubject()
	pcall(function()
		if not (Spectating and specMode == "subj" and specHumAddr and camAddr and offs.subj) then return end
		if specBadSince ~= nil then return end
		local cur = rdPtr(camAddr + offs.subj)
		if cur and cur ~= tonumber(specHumAddr) then
			pcall(memory_write, "uintptr_t", camAddr + offs.subj, specHumAddr)
		end
	end)
end

local function validateSpec(now)
	pcall(function()
		local gone = false
		pcall(function() gone = (Spectating.Parent == nil) end)
		if gone then stopSpectating() return end
		local char = Spectating.Character

		if specMode == "cf" then
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp then
				specBadSince = nil
				specHrp = hrp
			else
				specBadSince = specBadSince or now
				if now - specBadSince > 3 then stopSpectating() end
			end
			return
		end

		local hum = char and char:FindFirstChild("Humanoid")
		local ha = hum and addrOf(hum)
		if ha then
			specBadSince = nil
			specHrp = char:FindFirstChild("HumanoidRootPart")
			if ha ~= specHumAddr then
				specHumAddr = ha
				if camAddr then pcall(memory_write, "uintptr_t", camAddr + offs.subj, ha) end
				collectRunes(char)
			end
		else
			specBadSince = specBadSince or now
			if now - specBadSince > 1.0 then stopSpectating() end
		end
	end)
end

local function trustCheck(ma)
	pcall(function()
		if offsetTrusted or overriding or not camAddr or not ma then return end
		local cur = rdPtr(camAddr + offs.subj)
		if cur and cur == tonumber(ma) then offsetTrusted = true end
	end)
end

local camTypeCheck
do
local camTypeHits = 0
function camTypeCheck()
	pcall(function()
		if not offs.camtype or camTypeVerified == offs.camtype or not camAddr then return end
		local okR, v = pcall(memory_read, "int", camAddr + offs.camtype)
		if okR and v == CAM_CUSTOM then
			camTypeHits = camTypeHits + 1
			if camTypeHits >= 3 then markCamTypeVerified() end
		else
			camTypeHits = 0
		end
	end)
end
end

local function damageCheck(mh, myChar)
	pcall(function()
		local hp = mh and mh.Health
		if hp then
			local ma = myChar and addrOf(myChar)
			if ma ~= lastMyAddr then
				lastMyAddr = ma
			elseif Spectating and lastHP and hp < lastHP - 0.01 then
				stopSpectating()
			end
			lastHP = hp
		end
	end)
end

--==============================================================
-- MOUSE + REAL-LEADERBOARD
--==============================================================
local mousePos, resolveText, playerFromRealLeaderboard, restoreLeaderboard, tintTick
do
local function readText(d) return d.Text end
local function readTextColor(d) return d.TextColor3 end
local function writeTextColor(d, c) d.TextColor3 = c end
local function getDesc(r) return r:GetDescendants() end
local mouseFns = {
	function() local v = UserInputService:GetMouseLocation(); return v.X, v.Y end,
	function() local m = LocalPlayer:GetMouse(); return m.X, m.Y end,
	function()
		local ms = game:GetService("MouseService")
		local io = memory_read("uintptr_t", ms.Address + offs.io)
		local x = memory_read("float", io + offs.mpos)
		local y = memory_read("float", io + offs.mpos + 4)
		if x ~= x or y ~= y or x < -100 or y < -100 or x > 10000 or y > 10000 then error("bad mouse read") end
		return x, y
	end,
}
local mouseIdx = nil
function mousePos()
	if mouseIdx then
		local ok, x, y = pcall(mouseFns[mouseIdx])
		if ok and type(x) == "number" and type(y) == "number" then return x, y end
		mouseIdx = nil
	end
	for i, fn in ipairs(mouseFns) do
		local ok, x, y = pcall(fn)
		if ok and type(x) == "number" and type(y) == "number" and x == x and y == y and not (x == 0 and y == 0) then
			mouseIdx = i
			return x, y
		end
	end
end

local function isShown(obj, depth)
	local ok, res = pcall(function()
		local cur = obj
		for _ = 1, depth do
			if not cur then break end
			local okV, vis = pcall(function() return cur.Visible end)
			if okV and vis == false then return false end
			local okP, par = pcall(function() return cur.Parent end)
			if not okP then break end
			cur = par
		end
		return true
	end)
	return ok and res == true
end

function resolveText(clean, simp, allowLive)
	local ok, res = pcall(function()
		local p = nameMap[simp]
		if p then return p end

		local hit, n = nil, 0
		for nm, pl in pairs(nameMap) do
			if len(nm) >= 4 and find(simp, nm, 1, true) then
				if pl ~= hit then hit = pl; n = n + 1 end
			end
		end
		if n == 1 then return hit end

		if len(simp) >= 4 then
			hit, n = nil, 0
			for nm, pl in pairs(nameMap) do
				if find(nm, simp, 1, true) then
					if pl ~= hit then hit = pl; n = n + 1 end
				end
			end
			if n == 1 then return hit end
		end

		if allowLive and len(clean) >= 2 then
			for _, d in pairs(Data) do
				local ch = d.player.Character
				if ch then
					local okF, found = pcall(function() return ch:FindFirstChild(clean) end)
					if okF and found then return d.player end
				end
			end
		end
		return nil
	end)
	return ok and res or nil
end

-- cached view of the real leaderboard, built incrementally (30 labels per tick) so it never hitches
local lbList, lbMap, lbListAt, lbBuild = {}, {}, 0, nil
local lbOrig, lbApplied, lbNextApply = {}, {}, 0

local function findLbRoot()
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	return pg and pg:FindFirstChild("LeaderboardGui")
end

local function writeColorSafe(d, c) return pcall(writeTextColor, d, c) end

local function lbStep(now)
	if not lbBuild then
		if lbListAt ~= 0 and now - lbListAt < 4.0 then return end
		local okR, root = pcall(findLbRoot)
		if not okR or not root then lbListAt = now; lbList, lbMap = {}, {}; return end
		local okD, descs = pcall(getDesc, root)
		if not okD or type(descs) ~= "table" then lbListAt = now; return end
		lbBuild = { descs = descs, i = 1, list = {}, map = {} }
	end
	local b = lbBuild
	local last = b.i + 29
	if last > #b.descs then last = #b.descs end
	for i = b.i, last do
		local d = b.descs[i]
		local okT, txt = pcall(readText, d)
		if okT and type(txt) == "string" and txt ~= "" then
			b.list[#b.list + 1] = d
			local clean = cleanText(txt)
			local pl = resolveText(clean, simplify(clean), false)
			if pl then b.map[d] = pl end
		end
	end
	b.i = last + 1
	if b.i > #b.descs then
		lbList, lbMap, lbListAt, lbBuild = b.list, b.map, now, nil
		-- put back labels that are no longer mapped to a player
		for d in pairs(lbApplied) do
			if not lbMap[d] then
				if lbOrig[d] ~= nil then writeColorSafe(d, lbOrig[d]) end
				lbApplied[d], lbOrig[d] = nil, nil
			end
		end
	end
end

function restoreLeaderboard()
	pcall(function()
		for d in pairs(lbApplied) do
			if lbOrig[d] ~= nil then writeColorSafe(d, lbOrig[d]) end
			lbApplied[d], lbOrig[d] = nil, nil
		end
	end)
end

-- light blue = spectated, grey = NOT spawned in, otherwise the game's own colour
function tintTick(now)
	pcall(lbStep, now)
	if now < lbNextApply then return end
	lbNextApply = now + 0.4
	for d, pl in pairs(lbMap) do
		pcall(function()
			local want = nil
			if pl == Spectating then
				want = LBLUE
			else
				local dd = Data[pl]
				if dd and not dd.spawned then want = GREY end
			end
			if want then
				if lbOrig[d] == nil then
					local okC, c = pcall(readTextColor, d)
					if okC and c then lbOrig[d] = c end
				end
				if lbOrig[d] ~= nil then
					writeColorSafe(d, want)
					lbApplied[d] = want
				end
			elseif lbApplied[d] ~= nil then
				if lbOrig[d] ~= nil then writeColorSafe(d, lbOrig[d]) end
				lbApplied[d], lbOrig[d] = nil, nil
			end
		end)
	end
end

function playerFromRealLeaderboard(mx, my)
	local ok, res = pcall(function()
		local list = lbList
		if #list == 0 then
			-- cache not ready yet: one-off scan
			local root = findLbRoot()
			if not root then return nil end
			local okD, descs = pcall(getDesc, root)
			if not okD or type(descs) ~= "table" then return nil end
			list = descs
		end

		local bestArea, bestTxt
		for _, d in ipairs(list) do
			pcall(function()
				local okT, txt = pcall(readText, d)
				if okT and type(txt) == "string" and txt ~= "" then
					local okR, pos, size = pcall(function() return d.AbsolutePosition, d.AbsoluteSize end)
					if okR and pos then
						local w, h = 150, 18
						if size and (size.X or 0) > 0 and (size.Y or 0) > 0 then w, h = size.X, size.Y end
						if mx >= pos.X and mx <= pos.X + w and my >= pos.Y and my <= pos.Y + h and isShown(d, 8) then
							local area = w * h
							if not bestArea or area < bestArea then bestArea, bestTxt = area, txt end
						end
					end
				end
			end)
		end
		if not bestTxt then return nil end
		local clean = cleanText(bestTxt)
		return resolveText(clean, simplify(clean), true)
	end)
	return ok and res or nil
end

end

--==============================================================
-- STATE TICK
--==============================================================
local flipCount = 0
local function stateTick()
	local now = tick()
	refreshCam()

	local myChar, mh, ma
	pcall(function()
		myChar = LocalPlayer.Character
		mh = myChar and myChar:FindFirstChild("Humanoid")
		ma = mh and addrOf(mh)
	end)

	pcall(trustCheck, ma)
	pcall(damageCheck, mh, myChar)
	if Spectating then pcall(validateSpec, now) end

	local hasChar = false
	pcall(function() hasChar = mh ~= nil and (mh.Health or 0) > 0 end)

	-- menu <-> spawned: needs two ticks in a row (0.2 s)
	pcall(function()
		local rawMenu = not hasChar
		if rawMenu ~= inMenu then
			flipCount = flipCount + 1
			if flipCount >= 2 then
				flipCount = 0
				inMenu = rawMenu
				if inMenu then uiHidden = false; dragging = false end   -- overlay always visible on menu entry
				pcall(hardReset, inMenu and "menu" or "spawn")
			end
		else
			flipCount = 0
		end
	end)

	if hasChar then
		pcall(camTypeCheck)
		pcall(resetTick, now)
	end
	if Spectating then
		pcall(pinSubject)
		pcall(runeTick)
		pcall(followCheck, now)
	end
	pcall(tintTick, now)
end

task.spawn(function()
	while alive() do
		pcall(function()
			if not checkSession() then pcall(stateTick) end
		end)
		pcall(wait, 0.1)
	end
end)

--==============================================================
-- OVERLAY + INPUT + FRAME LOOP
--==============================================================
local Panel, Header
local Rows = {}

pcall(function()
	Panel = Drawing.new("Square")
	setp(Panel, "Filled", true)
	setp(Panel, "Color", Color3.fromRGB(20, 20, 20))
	setp(Panel, "Transparency", 0.6)
	setp(Panel, "ZIndex", 1)
	setp(Panel, "Visible", false)

	Header = newText(16, 2)
	setp(Header, "Color", Color3.fromRGB(255, 255, 255))
end)

local function cleanup()
	pcall(function() Panel:Remove() end)
	pcall(function() Header:Remove() end)
	pcall(function()
		for p, t in pairs(Rows) do pcall(function() t:Remove() end) Rows[p] = nil end
	end)
	pcall(restoreLeaderboard)
	pcall(restoreMenuScripts)
end

local prev1, prev2, prevH = false, false, false

local function pollInput()
	local okA, a = pcall(isrbxactive)
	inp.active = okA and a == true
	local ok1, d1 = pcall(ismouse1pressed)
	inp.m1 = ok1 and d1 == true
	local ok2, d2 = pcall(ismouse2pressed)
	inp.m2 = ok2 and d2 == true
end

local function keyDown(vk)
	local ok, v = pcall(iskeypressed, vk)
	return ok and v == true
end

-- H toggles the overlay (menu only). Polled every frame AND via InputBegan; shared debounce.
local lastHToggle = 0
local function toggleHide()
	local now = tick()
	if now - lastHToggle < 0.2 then return end
	lastHToggle = now
	if inMenu then
		uiHidden = not uiHidden
		if uiHidden then dragging = false end
	end
end

local function handleHideKey()
	local down = keyDown(0x48)
	local edge = down and not prevH
	prevH = down
	if edge and inp.active then toggleHide() end
end

local function clampOverlay()
	pcall(function()
		local vp = workspace.CurrentCamera.ViewportSize
		if vp and vp.X and vp.Y then
			ovX = clamp(ovX, 6, math.max(6, vp.X - 60))
			ovY = clamp(ovY, 6, math.max(6, vp.Y - 40))
		end
	end)
	if ovX < 6 then ovX = 6 end
	if ovY < 6 then ovY = 6 end
end

local function handleClicks()
	local d1, d2 = inp.m1, inp.m2
	local edge1, edge2 = d1 and not prev1, d2 and not prev2
	prev1, prev2 = d1, d2
	local clicked = edge1 or edge2
	local active = inp.active

	-- dragging the overlay by its header
	if dragging then
		if d1 and active and inMenu and not uiHidden then
			local dxm, dym = mousePos()
			if dxm then
				ovX, ovY = dxm - dragOX, dym - dragOY
				clampOverlay()
			end
		else
			dragging = false
		end
	end

	local mx, my
	if clicked and active then mx, my = mousePos() else clicked = false end

	local overlayHit = false
	if clicked and mx and inMenu and not uiHidden then
		local x, y = ovX, ovY
		if edge1 and mx >= x - 6 and mx <= x + PANEL_W - 6 and my >= y - 6 and my < y + ROW_H + 6 then
			dragging, dragOX, dragOY = true, mx - ovX, my - ovY
			overlayHit = true
		else
			for i, d in ipairs(Order) do
				local ry = y + 6 + i * ROW_H
				if mx >= x - 6 and mx <= x + PANEL_W - 6 and my >= ry and my < ry + ROW_H then
					pcall(toggleSpectate, d.player)
					overlayHit = true
					break
				end
			end
		end
	end

	if clicked and mx and not overlayHit then
		local target = playerFromRealLeaderboard(mx, my)
		if target then pcall(toggleSpectate, target) end
	end
end

-- Menu orbit camera, modelled on the default Roblox camera:
--   hold RIGHT MOUSE + drag = rotate, mouse wheel (or I / O, PageUp / PageDown, = / -) = zoom,
--   arrow keys also rotate.
local updateOrbit
do
local lastOrbitT, rmbWas, lastMX, lastMY = tick(), false, nil, nil
local vpW, vpH, vpAt = nil, nil, 0
local function readVP() local v = workspace.CurrentCamera.ViewportSize; return v.X, v.Y end
local function getMouseDelta() return UserInputService:GetMouseDelta() end

function updateOrbit()
	local now = tick()
	local dt = now - lastOrbitT
	if dt > 0.1 then dt = 0.1 end
	lastOrbitT = now

	if not (Spectating and specMode == "cf" and inMenu and inp.active) then
		rmbWas, lastMX, lastMY, wheelAcc = false, nil, nil, 0
		return
	end

	-- mouse look
	if inp.m2 and not dragging then
		local mx, my = mousePos()
		local dx, dy
		local okD, md = pcall(getMouseDelta)
		if okD and md and (md.X ~= 0 or md.Y ~= 0) then
			dx, dy = md.X, md.Y
		elseif rmbWas and mx and lastMX then
			dx, dy = mx - lastMX, my - lastMY
		end
		lastMX, lastMY = mx, my
		rmbWas = true

		-- never run out of room: if the cursor reaches a screen edge, put it back in the middle
		if MOUSE_RECENTER and mx then
			if now - vpAt > 2 then
				vpAt = now
				local okV, w, h = pcall(readVP)
				if okV and type(w) == "number" and w > 0 then vpW, vpH = w, h end
			end
			if vpW and (mx < 40 or my < 40 or mx > vpW - 40 or my > vpH - 40) then
				local cx, cy = floor(vpW / 2), floor(vpH / 2)
				if pcall(mousemoveabs, cx, cy) then lastMX, lastMY = cx, cy end
			end
		end

		if dx then
			camYaw = camYaw - dx * LOOK_SENS
			camPitch = clamp(camPitch + dy * LOOK_SENS, -1.2, 1.4)
		end
	else
		rmbWas, lastMX, lastMY = false, nil, nil
	end

	-- arrow keys
	if keyDown(0x25) then camYaw = camYaw + KEY_TURN * dt end                              -- Left
	if keyDown(0x27) then camYaw = camYaw - KEY_TURN * dt end                              -- Right
	if keyDown(0x26) then camPitch = clamp(camPitch - KEY_TURN * 0.7 * dt, -1.2, 1.4) end  -- Up
	if keyDown(0x28) then camPitch = clamp(camPitch + KEY_TURN * 0.7 * dt, -1.2, 1.4) end  -- Down

	-- zoom: wheel notches + keys, smoothed
	if wheelAcc ~= 0 then
		camDistTarget = clamp(camDistTarget * (WHEEL_ZOOM ^ wheelAcc), MIN_DIST, MAX_DIST)
		wheelAcc = 0
	end
	if keyDown(0x49) or keyDown(0x21) or keyDown(0xBB) then   -- I / PageUp / =
		camDistTarget = clamp(camDistTarget / (1 + KEY_ZOOM * dt), MIN_DIST, MAX_DIST)
	end
	if keyDown(0x4F) or keyDown(0x22) or keyDown(0xBD) then   -- O / PageDown / -
		camDistTarget = clamp(camDistTarget * (1 + KEY_ZOOM * dt), MIN_DIST, MAX_DIST)
	end
	local k = ZOOM_SMOOTH * dt
	if k > 1 then k = 1 end
	camDist = camDist + (camDistTarget - camDist) * k
end
end

local drawOverlay
do
local PANEL_TITLE = "Players   [H] = Hide   (click a name to spectate)"
local drawNextText, lastSpecDrawn = 0, nil

local function drawRow(i, d, x, y, refresh)
	local p = d.player
	local t = Rows[p]
	if not t then t = newText(14, 2); Rows[p] = t; refresh = true end
	if not t then return end
	if refresh then
		local nm = formatName(d.first, d.uber, d.last, d.rank, d.gender)
		local pre = (d.prestige and d.prestige > 0) and ("#" .. d.prestige .. " ") or ""
		setTxt(t, string.format("%s%s%s%s (%s)",
			(Spectating == p) and "> " or "",
			d.hidden and "[H] " or "",
			pre,
			(nm ~= "" and nm or "???"),
			p.Name))
		-- priority: spectated (light blue) > NOT spawned in (grey) > edict (gold) > white
		local col = d.color or WHITE
		if not d.spawned then col = GREY end
		if Spectating == p then col = LBLUE end
		setCol(t, col)
	end
	setPos(t, x, y + 6 + i * ROW_H)
	setVis(t, true)
end

function drawOverlay()
	local x, y = ovX, ovY

	if (not inMenu) or uiHidden then
		setVis(Panel, false)
		setVis(Header, false)
		for _, t in pairs(Rows) do setVis(t, false) end
		return
	end

	local now = tick()
	local refresh = (now >= drawNextText) or (lastSpecDrawn ~= Spectating)
	if refresh then drawNextText = now + 0.2; lastSpecDrawn = Spectating end

	setPos(Panel, x - 6, y - 6)
	setSize(Panel, PANEL_W, 30 + #Order * ROW_H)
	setVis(Panel, true)
	setTxt(Header, PANEL_TITLE)
	setPos(Header, x, y)
	setVis(Header, true)

	local inOrder = {}
	for i, d in ipairs(Order) do
		inOrder[d.player] = true
		pcall(drawRow, i, d, x, y, refresh)
	end
	for p, t in pairs(Rows) do
		if not inOrder[p] then pcall(function() t:Remove() end) Rows[p] = nil end
	end
end
end

local function frame()
	pcall(pollInput)
	pcall(handleHideKey)
	pcall(updateOrbit)        -- input first ...
	pcall(cfTick)             -- ... then apply it immediately (writer #1)
	pcall(handleClicks)
	pcall(drawOverlay)
end

local conns = {}
local function disconnectAll()
	for i, c in ipairs(conns) do
		pcall(function() c:Disconnect() end)
		conns[i] = nil
	end
end

pcall(function()
	conns[#conns + 1] = RunService.RenderStepped:Connect(function()
		pcall(function()
			if not alive() or checkSession() then
				cleanup()
				if not hopped then pcall(stopSpectating, inMenu and "menu" or "spawn") end
				disconnectAll()
				return
			end
			frame()
		end)
	end)
end)

-- writer #2
pcall(function()
	conns[#conns + 1] = RunService.Heartbeat:Connect(function() pcall(cfTick) end)
end)

-- event-based H (never misses a quick tap) and mouse wheel zoom
pcall(function()
	conns[#conns + 1] = UserInputService.InputBegan:Connect(function(input, gp)
		pcall(function()
			if gp then return end
			if input.KeyCode == Enum.KeyCode.H then
				prevH = true      -- tell the poller this press is already handled
				toggleHide()
			end
		end)
	end)
end)

pcall(function()
	conns[#conns + 1] = UserInputService.InputChanged:Connect(function(input)
		pcall(function()
			if input.UserInputType == Enum.UserInputType.MouseWheel then
				wheelAcc = wheelAcc + (input.Position.Z or 0)
			end
		end)
	end)
end)

pcall(notify, "Loaded. The player list appears in the main menu.", "Spectate", 4)

end)

-- if anything above errored, stop silently: bumping the generation stops any loops that did start
if not ranOk then
	pcall(function() SP_GEN = (SP_GEN or 0) + 1 end)
end
