--// Rogue Lineage — Matcha
--//   * Spectate (menu player list) — Matcha port (v14): leaderboard rows are now also linked to players by
--//     their on-screen order (the game places row N at (N-1)*20, in a fixed sort order), not only by text
--//   * "Rogue Lineage" Matcha tab: Spectate on/off toggle + named configs (one JSON file each in
--//     RogueLineage/configs/, pick which one to load; the last one used is autoloaded at start)
--//
--// Only runs in PlaceId 5208655184 or 3541987450. In any other place NOTHING below the gate executes.
--// The whole script body runs inside one pcall, so an error anywhere can't take anything else down.
--//
--// Locals: the main chunk only has `RL`. Everything else lives on the RL table, and the spectate body
--// keeps its own do-blocks (v13) so it stays well under Lua 5.1's 200-locals-per-function limit.
--//
--// ADDING A FEATURE LATER: add one row to RL.items (id = the UI widget id, key = the name in the JSON,
--// default = value used when the config has nothing). Save/Load/autoload then handle it automatically.

--==============================================================
-- PLACE GATE (first thing in the script)
--==============================================================
local ALLOWED_PLACES = {
	[5208655184] = true, -- Gaia
	[3541987450] = true, -- Khei
}
local PLACE_OK = false
do
	local okP, pid = pcall(function() return game.PlaceId end)
	pid = okP and tonumber(pid) or nil
	if pid and ALLOWED_PLACES[pid] then PLACE_OK = true end
end

if PLACE_OK then

local mainOk, mainErr = pcall(function()

local RL = {
	dir     = "RogueLineage",
	cfgDir  = "RogueLineage/configs",        -- one JSON file per named config
	legacy  = "RogueLineage/config.json",    -- old single-file config, still read as "default"
	lastFile = "RogueLineage/last.txt",      -- remembers which config to autoload
	name    = "default",                     -- currently selected config
	nameId  = "rl_cfg_name",
	comboId = "rl_cfg_pick",
	indexFile = "RogueLineage/index.txt",    -- names of saved configs (so listing never depends on listfiles)
	base    = 0,                             -- dropdown index base: 0 = first item is 0. If the wrong config loads, set 1.
	pick    = 1,                             -- selected position in RL.list (always 1-based here)
	list    = {},
	none    = { "(none saved yet)" },
	listAt  = 0,
	specId  = "rl_spectate",
	running = false,
	ready   = false,
	cfg     = {},
	items   = {
		{ id = "rl_spectate", key = "spectate", default = true },
	},
}

RL_GEN = (RL_GEN or 0) + 1
RL.gen = RL_GEN

--==============================================================
-- CONFIG (flat JSON: booleans, numbers, simple strings)
--==============================================================
function RL.encode(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys)
	local out = {}
	for _, k in ipairs(keys) do
		local v = t[k]
		local s
		if type(v) == "string" then
			s = '"' .. (string.gsub(v, '[\\"]', '\\%0')) .. '"'
		elseif type(v) == "boolean" or type(v) == "number" then
			s = tostring(v)
		end
		if s then out[#out + 1] = '"' .. tostring(k) .. '":' .. s end
	end
	return "{" .. table.concat(out, ",") .. "}"
end

function RL.decode(body)
	local t = {}
	for k, v in string.gmatch(body, '"([^"]+)"%s*:%s*"([^"]*)"') do t[k] = v end
	for k, v in string.gmatch(body, '"([^"]+)"%s*:%s*([^,}%s"]+)') do
		if v == "true" then t[k] = true
		elseif v == "false" then t[k] = false
		elseif tonumber(v) then t[k] = tonumber(v) end
	end
	return t
end

function RL.read(name)
	local ok, body = pcall(function()
		local path = RL.cfgDir .. "/" .. name .. ".json"
		if isfile(path) then return readfile(path) end
		if name == "default" and isfile(RL.legacy) then return readfile(RL.legacy) end
	end)
	if ok and type(body) == "string" and body ~= "" then
		local ok2, t = pcall(RL.decode, body)
		if ok2 and type(t) == "table" then return t, true end
	end
	return {}, false
end

function RL.write(name, t)
	return pcall(function()
		if not isfolder(RL.dir) then makefolder(RL.dir) end
		if not isfolder(RL.cfgDir) then makefolder(RL.cfgDir) end
		writefile(RL.cfgDir .. "/" .. name .. ".json", RL.encode(t))
	end)
end

-- config names: letters, digits, _ and - only (spaces become _), max 32 chars
function RL.clean(s)
	s = tostring(s or "")
	s = string.gsub(s, "%s+", "_")
	s = string.gsub(s, "[^%w_%-]", "")
	if s == "" then s = "default" end
	return string.sub(s, 1, 32)
end

function RL.setLast(name)
	pcall(function()
		if not isfolder(RL.dir) then makefolder(RL.dir) end
		writefile(RL.lastFile, name)
	end)
end

function RL.getLast()
	local ok, v = pcall(function()
		if isfile(RL.lastFile) then return readfile(RL.lastFile) end
	end)
	if ok and type(v) == "string" and v ~= "" then return RL.clean(v) end
	return nil
end

function RL.exists(name)
	local ok, r = pcall(function()
		return isfile(RL.cfgDir .. "/" .. name .. ".json") or (name == "default" and isfile(RL.legacy))
	end)
	return ok and r == true
end

function RL.readIndex()
	local names = {}
	pcall(function()
		if isfile(RL.indexFile) then
			for n in string.gmatch(readfile(RL.indexFile), "[^\r\n]+") do names[#names + 1] = n end
		end
	end)
	return names
end

function RL.addIndex(name)
	local names = RL.readIndex()
	for _, n in ipairs(names) do
		if n == name then return end
	end
	names[#names + 1] = name
	pcall(function()
		if not isfolder(RL.dir) then makefolder(RL.dir) end
		writefile(RL.indexFile, table.concat(names, "\n"))
	end)
end

-- rebuild the list of saved configs: the index file, plus anything listfiles can see, only if the file exists
function RL.refresh()
	local seen, names = {}, {}
	local function add(n)
		if n and n ~= "" and not seen[n] and RL.exists(n) then
			seen[n] = true
			names[#names + 1] = n
		end
	end
	for _, n in ipairs(RL.readIndex()) do add(n) end
	pcall(function()
		if isfolder(RL.cfgDir) then
			for _, p in ipairs(listfiles(RL.cfgDir)) do
				add(string.match(tostring(p), "([^/\\]+)%.json$"))
			end
		end
	end)
	add("default")
	table.sort(names)
	RL.list = names
	RL.listAt = tick()
	if RL.pick > #names or RL.pick < 1 then RL.pick = 1 end
end

-- point the dropdown at a config
function RL.select(name)
	for i, n in ipairs(RL.list) do
		if n == name then
			RL.pick = i
			pcall(UI.SetValue, RL.comboId, i - 1 + RL.base)
			return
		end
	end
end

function RL.autoName()
	local used = {}
	for _, n in ipairs(RL.list) do used[n] = true end
	local i = 1
	while used["config_" .. i] do i = i + 1 end
	return "config_" .. i
end

-- value for a config key: the saved one if it has the right type, otherwise the item's default
function RL.val(key)
	for _, it in ipairs(RL.items) do
		if it.key == key then
			local v = RL.cfg[key]
			if type(v) == type(it.default) then return v end
			return it.default
		end
	end
end

function RL.save(name)
	name = RL.clean(name)
	local t = {}
	for _, it in ipairs(RL.items) do
		local ok, v = pcall(UI.GetValue, it.id)
		if ok and type(v) == type(it.default) then t[it.key] = v else t[it.key] = RL.val(it.key) end
	end
	RL.cfg = t
	local ok = RL.write(name, t)
	ok = ok and RL.exists(name)   -- make sure the file really was created
	if ok then
		RL.name = name
		RL.setLast(name)
		RL.addIndex(name)
		RL.refresh()
		RL.select(name)
	end
	return ok
end

function RL.load(name)
	name = RL.clean(name)
	local t, found = RL.read(name)
	if not found then return false end
	RL.cfg = t
	RL.name = name
	RL.setLast(name)
	for _, it in ipairs(RL.items) do pcall(UI.SetValue, it.id, RL.val(it.key)) end
	RL.select(name)
	return true
end

--==============================================================
-- SPECTATE ON/OFF
--==============================================================
function RL.stopSpectate()
	-- bumping the generation makes the running copy clean itself up (camera, leaderboard, overlay) and exit
	pcall(function() SP_GEN = (SP_GEN or 0) + 1 end)
end

function RL.apply(on)
	on = (on == true)
	if on == RL.running then return end
	RL.running = on
	if on then RL.startSpectate() else RL.stopSpectate() end
end

--==============================================================
-- SPECTATE (original script body)
--==============================================================
function RL.startSpectate()
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
local DEFAULTS = { subj = 176, camtype = 288, campos = 228, camrot = 192, io = 232, mpos = 188, textcolor = 2784 }
local GAME_CAM_MAX_DIST = 100
local ROW_H, PANEL_W = 18, 430
local RESET_WINDOW = 3
local OVERLAY_X, OVERLAY_Y = 20, 200      -- starting position (drag the header to move it)
local REVEAL_HIDDEN = true                -- always on: unhide hidden players while in the menu (put back on spawn / when stopped)
local MENU_METHOD   = "cf"                -- "cf" = CFrame follow, "subj" = CameraSubject
local FOLLOW_DIST   = 12                  -- starting menu follow distance
local MIN_DIST, MAX_DIST = 0, 200         -- 0 = camera sits right inside the character

-- camera feel
local LOOK_SENS     = 0.0065              -- radians per pixel (raise = faster turning)
local KEY_TURN      = 2.4                 -- Left/Right/Up/Down arrows, radians per second
local KEY_ZOOM      = 45                  -- W/S, PageUp/PageDown, =/-  (studs per second, constant speed)
local WHEEL_ZOOM    = 7                   -- studs per wheel notch
local ZOOM_SMOOTH   = 14                  -- higher = snappier zoom (0 = instant)
local MOUSE_RECENTER = true               -- warps the cursor to screen centre if you drag into an edge
local LOOK_SMOOTH   = 60                  -- how fast the shown camera angle catches up to your mouse (higher = tighter, 0 = raw / no smoothing)
local KEY_POLL      = 0.03                -- seconds between keyboard reads for the orbit keys (state is reused in between)

-- flicker vs lag: each extra writer fights the game's camera harder but costs speed
local DRIVER_THREADS = 0                  -- tight-loop camera writers (RenderStepped + Heartbeat also write)

local LBLUE = Color3.fromRGB(120, 200, 255)   -- spectated player
local GREY  = Color3.fromRGB(130, 130, 130)   -- NOT spawned in
local WHITE, GOLD = Color3.fromRGB(240, 240, 240), Color3.fromRGB(255, 214, 81)

local lower, find, gsub, len = string.lower, string.find, string.gsub, string.len
local abs, sqrt, sin, cos, floor = math.abs, math.sqrt, math.sin, math.cos, math.floor

--==============================================================
-- HELPERS
--==============================================================
local setp
do
local function rawSet(obj, name, value) obj[name] = value end
function setp(obj, name, value)
	return pcall(rawSet, obj, name, value)
end
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
local resetUntil = 0
local inMenu = false
local cfPropBad, cfErrCount = false, 0
local cfSubjSet = false                    -- true while menu spectate has CameraSubject pointed at the target
local camAddr, camObj = nil, nil

-- overlay UI state
local uiHidden = false
local ovX, ovY = OVERLAY_X, OVERLAY_Y
local dragging, dragOX, dragOY = false, 0, 0

-- menu orbit camera state (camYaw/camPitch/camDistTarget = where your input points; disp/camDist = what is shown)
local camYaw, camPitch, camDist, camDistTarget = 0, 0.3, FOLLOW_DIST, FOLLOW_DIST
local wheelAcc = 0
local disp = { yaw = 0, pitch = 0.3, t = 0 }   -- the angles the camera actually shows (eased toward camYaw/camPitch)
local interactAt = 0                       -- last time you orbited/zoomed: background scans pause while this is recent
local dragTick                             -- defined further down (lets the extra writers move the overlay too)

-- per-frame input snapshot
local inp = { active = false, m1 = false, m2 = false }

local Data, Order = {}, {}
local nameMap = {}

--==============================================================
-- OFFSETS (updated once, when the script runs)
--==============================================================
local offs = { subj = DEFAULTS.subj, camtype = DEFAULTS.camtype, campos = DEFAULTS.campos,
	camrot = DEFAULTS.camrot, io = DEFAULTS.io, mpos = DEFAULTS.mpos, textcolor = DEFAULTS.textcolor }
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

local function applyBody(body)
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
			textcolor = parseOffset(body, "GuiObject", "TextColor3") or DEFAULTS.textcolor,
		}
		local changed = false
		for k, v in pairs(n) do
			if offs[k] ~= v then changed = true end
		end
		if changed and Spectating then pcall(stopSpectating) end
		for k, v in pairs(n) do offs[k] = v end
		if changed then offsetTrusted, camTypeBad = false, false end
		return true
	end)
	return ok and res == true
end

local function refreshOffsets()
	pcall(function()
		-- live offsets first, then the cached copy, otherwise the built-in DEFAULTS
		local ok, body = pcall(httpget, OFFSETS_URL)
		if ok and type(body) == "string" and body:find('"Offsets"') and applyBody(body) then
			pcall(writefile, CACHE_FILE, body)
			return
		end
		local okc, cached = pcall(function() if isfile(CACHE_FILE) then return readfile(CACHE_FILE) end end)
		if okc and type(cached) == "string" then applyBody(cached) end
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
			if first == "Justinian" or first == " Undying Justinian " then title = "Emperor" end
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
-- PLAYER SAMPLING (attributes + name map) — polling, no events
--==============================================================
-- name data can live in different places depending on the map: Player attribute, Character attribute,
-- or a ValueObject child (StringValue etc.) of the Player or Character. Check all of them.
local function nameAttr(p, char, key)
	local v = attr(p, key)
	if v ~= nil and v ~= "" then return v end
	-- Khei: Player.leaderstats.<key> value objects (StringValue / BoolValue / IntValue)
	local okL, lv = pcall(function()
		local ls = p:FindFirstChild("leaderstats")
		local o = ls and ls:FindFirstChild(key)
		if o then return o.Value end
	end)
	if okL and lv ~= nil and lv ~= "" then return lv end
	if char then
		local okC, c = pcall(function() return char:GetAttribute(key) end)
		if okC and c ~= nil and c ~= "" then return c end
	end
	local holders = { p, char }
	for i = 1, 2 do
		local holder = holders[i]
		if holder then
			local okV, r = pcall(function()
				local o = holder:FindFirstChild(key)
				if o then return o.Value end
			end)
			if okV and r ~= nil and r ~= "" then return r end
		end
	end
	return nil
end

-- prints (once) everything attached to a player that has no name data, so the right place can be found
local dumped = false
local function dumpOnce(p, char)
	if dumped then return end
	dumped = true
	pcall(function()
		local function list(inst, label)
			local parts = {}
			pcall(function()
				for k, v in pairs(inst:GetAttributes()) do parts[#parts + 1] = "@" .. tostring(k) .. "=" .. tostring(v) end
			end)
			pcall(function()
				for _, c in ipairs(inst:GetChildren()) do
					local cn = ""
					pcall(function() cn = c.ClassName end)
					local val = ""
					pcall(function() if string.find(cn, "Value") then val = "=" .. tostring(c.Value) end end)
					parts[#parts + 1] = tostring(c.Name) .. "[" .. cn .. "]" .. val
				end
			end)
			pcall(print, "[SPEC] no name data for " .. tostring(p.Name) .. " (" .. label .. "): " .. table.concat(parts, ", "))
		end
		list(p, "Player")
		if char then list(char, "Character") end
	end)
end

-- sets "Hidden" wherever this map keeps it: Gaia = Player attribute, Khei = Player.leaderstats.Hidden value
local function setHidden(p, val)
	pcall(function()
		if p:GetAttribute("Hidden") ~= nil then p:SetAttribute("Hidden", val) end
	end)
	pcall(function()
		local ls = p:FindFirstChild("leaderstats")
		local o = ls and ls:FindFirstChild("Hidden")
		if o then o.Value = val end
	end)
end

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

			local char = p.Character
			d.first, d.uber, d.last = nameAttr(p, char, "FirstName"), nameAttr(p, char, "UberTitle"), nameAttr(p, char, "LastName")
			d.rank, d.gender = nameAttr(p, char, "HouseRank"), nameAttr(p, char, "Gender")
			d.prestige, d.edict = nameAttr(p, char, "Prestige"), nameAttr(p, char, "MaxEdict")

			local hid = nameAttr(p, char, "Hidden")
			if reveal and p ~= LocalPlayer then
				if hid == true then
					d.revealed = true
					setHidden(p, false)
				end
			elseif d.revealed then
				setHidden(p, true)
				d.revealed = false
			end
			d.hidden = (hid == true) or d.revealed
			d.color = d.edict and GOLD or WHITE

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
			d.full = formatName(d.first, d.uber, d.last, d.rank, d.gender)   -- cached for the overlay rows
			if d.full == "" then
				-- no character-name data found: show the display name / username instead of ???
				if char then dumpOnce(p, char) end
				if okD and type(dn) == "string" and dn ~= "" then d.full = dn else d.full = tostring(p.Name) end
			end
			add(d.full)
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
			-- skipped while dragging the overlay or orbiting/zooming: these scans are what makes the camera hitch
			if not dragging and (tick() - interactAt) > 0.3 and not checkSession() then pcall(sample) end
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
			elseif mode == "cf" and cfSubjSet then
				-- menu spectate pointed CameraSubject at the target: give it back (own humanoid, else none)
				pcall(function()
					local ca = refreshCam()
					if not (ca and offs.subj) then return end
					local mh = myHumanoid()
					local ma = mh and addrOf(mh)
					memory_write("uintptr_t", ca + offs.subj, (reason ~= "menu" and ma) or 0)
				end)
			end
		end
		pcall(restoreCamType)
	end)
	cfSubjSet = false
	camCheckAt = nil
	runeDecals = {}
	Spectating, specHumAddr, specBadSince, specHrp, specMode = nil, nil, nil, nil, nil
end

-- runs on EVERY menu <-> spawned change: drop any spectate, put the camera back, and (on spawn)
-- keep forcing the camera onto our own humanoid for RESET_WINDOW seconds (see resetTick)
hardReset = function(kind)
	pcall(function()
		pcall(stopSpectating, kind)
		if kind == "spawn" then resetUntil = tick() + RESET_WINDOW end
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
		elseif inMenu then
			logOnce("Menu CameraSubject mode didn't follow - the menu camera script is overriding it")
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

		-- MENU: CFrame follow (CameraType becomes Scriptable and we write the CFrame ourselves).
		-- MenuClient only pans/tweens the camera while CameraSubject is NOT inside the workspace, so
		-- we also point CameraSubject at the target's Humanoid: that makes its loop stand down
		-- instead of fighting our CFrame writes (this was the flicker).
		if mode == "cf" then
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if not hrp then logOnce("Target has no HumanoidRootPart - can't spectate") return false end
			if not overriding then
				camTypeOrig, camTypeWritten = nil, nil
				setCamType(ca, CAM_SCRIPTABLE)
				camYaw, camPitch, camDist, camDistTarget = 0, 0.3, FOLLOW_DIST, FOLLOW_DIST
				disp.yaw, disp.pitch, disp.t = 0, 0.3, tick()
				wheelAcc = 0
			end
			overriding = true
			Spectating, specHumAddr, specBadSince, specHrp, specMode = player, nil, nil, hrp, "cf"
			cfPropBad, cfErrCount = false, 0

			local hum = char:FindFirstChild("Humanoid")
			local ha = hum and addrOf(hum)
			if ha and offs.subj then
				local safe = cfSubjSet
				if not safe then
					-- same sanity check as the spawned-in path: the offset must really hold a subject pointer
					local cur = rdPtr(ca + offs.subj)
					local mine = myHumanoid()
					local myAddr = mine and addrOf(mine)
					if myAddr and cur == tonumber(myAddr) then offsetTrusted = true end
					safe = offsetTrusted or ((not myAddr) and cur ~= nil and (cur == 0 or cur > 65536))
				end
				if safe and pcall(memory_write, "uintptr_t", ca + offs.subj, ha) then
					cfSubjSet, specHumAddr = true, ha
				end
			end
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
		collectRunes(char)
		collectRunes(LocalPlayer.Character)
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
-- Your input only changes camYaw/camPitch/camDistTarget (in updateOrbit). Every writer that calls this
-- eases the SHOWN angles toward them by real elapsed time, so the motion is continuous at whatever rate
-- the writers run, instead of stepping once per input frame.
--==============================================================
local cfTick
do
-- Other players' parts only get a new position a handful of times per second, so following the raw
-- position is choppy. Between updates the focus is moved ahead along the player's real velocity (read
-- from the part; if that isn't available it is measured from the updates), so it tracks where they
-- actually are right now instead of where they were at the last update. A smoothing pass then hides the
-- correction when each new update lands (that is what removes the warble); the target is aimed ahead by
-- the delay that smoothing adds, so the camera still ends up on the player rather than behind them.
local FOLLOW_SMOOTH = 12                   -- higher = tighter to the player, lower = softer / less warble (the lag it would add is cancelled out)
local F = { hrp = nil }

local function readVel(hrp)
	local ok, v = pcall(function() return hrp.AssemblyLinearVelocity end)
	if not (ok and v and type(v.X) == "number") then
		ok, v = pcall(function() return hrp.Velocity end)
	end
	if ok and v and type(v.X) == "number" then return v.X, v.Y, v.Z end
end

local function readTarget(dt)
	local hrp = specHrp
	local p = hrp.Position
	local px, py, pz = p.X, p.Y, p.Z
	local now = tick()

	if hrp ~= F.hrp then                   -- new target (or respawned): start exactly on it
		F.hrp = hrp
		F.lx, F.ly, F.lz = px, py, pz      -- last position received
		F.sx, F.sy, F.sz = px, py, pz      -- focus shown
		F.mx, F.my, F.mz = 0, 0, 0         -- velocity measured from the updates (fallback)
		F.seen = now
		return px, py, pz
	end

	if px ~= F.lx or py ~= F.ly or pz ~= F.lz then
		local gap = now - F.seen
		F.seen = now
		local mx, my, mz = 0, 0, 0
		if gap >= 0.012 and gap < 0.25 then
			mx, my, mz = (px - F.lx) / gap, (py - F.ly) / gap, (pz - F.lz) / gap
		end
		F.mx, F.my, F.mz = F.mx + (mx - F.mx) * 0.5, F.my + (my - F.my) * 0.5, F.mz + (mz - F.mz) * 0.5
		F.lx, F.ly, F.lz = px, py, pz
	elseif now - F.seen > 0.15 then
		F.mx, F.my, F.mz = 0, 0, 0
	end

	-- real velocity if the part reports one, otherwise the measured one
	local vx, vy, vz = F.mx, F.my, F.mz
	local tx, ty, tz = readVel(hrp)
	if tx and (tx * tx + ty * ty + tz * tz) > 0.25 then vx, vy, vz = tx, ty, tz end

	local ex = now - F.seen
	if ex > 0.1 then ex = 0.1 end
	ex = ex + 1 / FOLLOW_SMOOTH            -- aim ahead by exactly the lag the smoothing adds, so it nets out to none
	local gx, gy, gz = F.lx + vx * ex, F.ly + vy * ex, F.lz + vz * ex

	local dx, dy, dz = gx - F.sx, gy - F.sy, gz - F.sz
	if dx * dx + dy * dy + dz * dz > 900 then   -- teleported / respawned far away: snap
		F.sx, F.sy, F.sz = gx, gy, gz
		return gx, gy, gz
	end

	local k = 1 - 2.718281828 ^ (-FOLLOW_SMOOTH * dt)
	F.sx, F.sy, F.sz = F.sx + dx * k, F.sy + dy * k, F.sz + dz * k
	return F.sx, F.sy, F.sz
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
	-- time since the last call (any writer)
	local now = tick()
	local dt = now - disp.t
	disp.t = now
	if dt > 0.1 then dt = 0.1 elseif dt < 0 then dt = 0 end

	local ok, tx, ty, tz = pcall(readTarget, dt)
	if not ok or type(tx) ~= "number" then return end

	-- ease the shown angles / zoom toward the input targets by that time
	local kl = (LOOK_SMOOTH > 0) and (1 - 2.718281828 ^ (-LOOK_SMOOTH * dt)) or 1
	local kz = (ZOOM_SMOOTH > 0) and (1 - 2.718281828 ^ (-ZOOM_SMOOTH * dt)) or 1
	disp.yaw = disp.yaw + (camYaw - disp.yaw) * kl
	disp.pitch = disp.pitch + (camPitch - disp.pitch) * kl
	camDist = camDist + (camDistTarget - camDist) * kz

	cfCalls = cfCalls + 1
	if offs.camtype and cfCalls % 15 == 0 then pcall(enforceScriptable) end

	local fx, fy, fz = tx, ty + 1.5, tz
	local cp = cos(disp.pitch)
	local px = fx + camDist * sin(disp.yaw) * cp
	local py = fy + camDist * sin(disp.pitch)
	local pz = fz + camDist * cos(disp.yaw) * cp

	-- aim one unit back toward the character along the orbit direction. Same view as looking at the
	-- character when zoomed out, but it stays valid at distance 0 (camera inside the character)
	local ux, uy, uz = sin(disp.yaw) * cp, sin(disp.pitch), cos(disp.yaw) * cp
	local lx, ly, lz = px - ux, py - uy, pz - uz

	if not cfPropBad and camObj then
		if pcall(writeCamProp, px, py, pz, lx, ly, lz) then
			cfErrCount = 0
		else
			cfErrCount = cfErrCount + 1
			if cfErrCount >= 5 then cfPropBad = true end
		end
	elseif cfPropBad and offs.camrot and offs.campos then
		pcall(writeCamMem, px, py, pz, lx, ly, lz)
	end
end

function cfTick()
	if alive() and Spectating and specMode == "cf" and inMenu then pcall(cfFollow) end
end
end

-- extra tight-loop writers (they also move the overlay while it is being dragged)
for _ = 1, DRIVER_THREADS do
	pcall(function()
		task.spawn(function()
			while alive() do
				if dragging then pcall(dragTick) else pcall(cfTick) end
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
		if not (Spectating and (specMode == "subj" or (specMode == "cf" and cfSubjSet)) and specHumAddr and camAddr and offs.subj) then return end
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
			if cfSubjSet and camAddr and offs.subj then
				-- target respawned / humanoid changed: follow it; if it's gone, never leave a stale pointer behind
				local hum = char and char:FindFirstChild("Humanoid")
				local ha = hum and addrOf(hum)
				if ha then
					if ha ~= specHumAddr then
						specHumAddr = ha
						pcall(memory_write, "uintptr_t", camAddr + offs.subj, ha)
					end
				elseif specHumAddr then
					specHumAddr = nil
					pcall(memory_write, "uintptr_t", camAddr + offs.subj, 0)
				end
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
local function getDesc(r) return r:GetDescendants() end

-- leaderboard name colours as float triples (0..1), written straight into the label's TextColor3 memory
-- (the property write is not supported by this Matcha build)
local LB_RED  = { 1, 0, 0 }                           -- spawned in (255, 0, 0)
local LB_BLUE = { 120 / 255, 200 / 255, 1 }           -- spectated
local LB_GREY = { 130 / 255, 130 / 255, 130 / 255 }   -- NOT spawned in

local function colEq(a, b)
	return abs(a[1] - b[1]) < 0.01 and abs(a[2] - b[2]) < 0.01 and abs(a[3] - b[3]) < 0.01
end

-- returns {r, g, b} or nil when what sits at the offset doesn't look like a colour (wrong / outdated offset)
local function readTextColor(d)
	local off, a = offs.textcolor, d.Address
	if not (off and a) then return nil end
	local r = memory_read("float", a + off)
	local g = memory_read("float", a + off + 4)
	local b = memory_read("float", a + off + 8)
	if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then return nil end
	if r ~= r or g ~= g or b ~= b then return nil end
	if r < -0.01 or r > 1.01 or g < -0.01 or g > 1.01 or b < -0.01 or b > 1.01 then return nil end
	return { r, g, b }
end

local function writeTextColor(d, c)
	local off, a = offs.textcolor, d.Address
	if not (off and a) then return end
	memory_write("float", a + off, c[1])
	memory_write("float", a + off + 4, c[2])
	memory_write("float", a + off + 8, c[3])
end
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

-- a label is only touched through memory while it is still inside the CURRENT LeaderboardGui
-- (a destroyed / recreated leaderboard must never be written to)
local function labelAlive(d)
	local ok, res = pcall(function()
		local root = findLbRoot()
		if not root then return false end
		local ra = addrOf(root)
		local cur = d
		for _ = 1, 12 do
			local par = cur.Parent
			if par == nil then return false end
			local pa = addrOf(par)
			if pa and ra and pa == ra then return true end
			cur = par
		end
		return false
	end)
	return ok and res == true
end

local function writeColorSafe(d, c)
	if not labelAlive(d) then return false end
	return pcall(writeTextColor, d, c)
end

-- Row N on screen = Nth player in the game's sort order (no text needed).
-- Both maps place each shown row at Position = (0, 0, 0, (N-1) * 20) and show a player when their
-- FirstName is non-empty and Hidden is false. Gaia never lists you while you are hidden; Khei always lists you.
local KHEI = false
pcall(function() KHEI = (tonumber(game.PlaceId) == 3541987450) end)

local function mapRowsByOrder()
	local byAddr = {}
	pcall(function()
		local root = findLbRoot()
		local sf = root.MainFrame.ScrollingFrame
		local rows = {}
		for _, r in ipairs(sf:GetChildren()) do
			local okV, vis = pcall(function() return r.Visible end)
			local okT, txt = pcall(readText, r)
			if okV and vis == true and okT and type(txt) == "string" then
				local y
				local okP, py = pcall(function() return r.Position.Y.Offset end)
				if okP and type(py) == "number" then y = py end
				if y == nil then
					local okA, ay = pcall(function() return r.AbsolutePosition.Y end)
					if okA then y = ay end
				end
				rows[#rows + 1] = { addr = addrOf(r), y = y or 0 }
			end
		end
		table.sort(rows, function(a, b) return a.y < b.y end)

		local expected = {}
		for _, d in ipairs(Order) do
			local shown = (not d.hidden) or d.revealed or (KHEI and d.player == LocalPlayer)
			if d.first and d.first ~= "" and shown then expected[#expected + 1] = d.player end
		end

		if #rows ~= #expected then return end   -- out of sync with the game's list: skip this pass
		for i, r in ipairs(rows) do
			if r.addr then byAddr[r.addr] = expected[i] end
		end
	end)
	return byAddr
end

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
		-- fill labels the text couldn't resolve using their on-screen order
		local byPos = mapRowsByOrder()

		-- self-check against the text matches: any contradiction means the order list is off, so don't use it
		local clash = 0
		for _, d in ipairs(b.list) do
			local a = addrOf(d)
			local op = a and byPos[a]
			if op and b.map[d] and b.map[d] ~= op then clash = clash + 1 end
		end
		if clash == 0 then
			for _, d in ipairs(b.list) do
				if not b.map[d] then
					local a = addrOf(d)
					if a and byPos[a] then b.map[d] = byPos[a] end
				end
			end
		end

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

-- light blue = spectated, red = spawned in, grey = NOT spawned in
-- (the game's own colour is remembered per label and put back when a label is no longer tinted)
function tintTick(now)
	pcall(lbStep, now)
	if now < lbNextApply then return end
	lbNextApply = now + 0.4
	for d, pl in pairs(lbMap) do
		pcall(function()
			local want = nil
			if pl == Spectating then
				want = LB_BLUE
			else
				local dd = Data[pl]
				if dd then
					if dd.spawned then want = LB_RED else want = LB_GREY end
				end
			end
			if want then
				if not labelAlive(d) then return end
				local cur = readTextColor(d)
				if not cur then return end   -- offset doesn't point at a colour: don't write anything
				if lbOrig[d] == nil then
					lbOrig[d] = cur
				elseif lbApplied[d] ~= nil and not colEq(cur, lbApplied[d]) then
					lbOrig[d] = cur          -- the game changed the colour itself (e.g. MaxEdict): remember the new one
				end
				if not colEq(cur, want) then writeColorSafe(d, want) end
				lbApplied[d] = want
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

		local bestArea, bestTxt, bestD
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
							if not bestArea or area < bestArea then bestArea, bestTxt, bestD = area, txt, d end
						end
					end
				end
			end)
		end
		if not bestTxt then return nil end

		-- the cached text/order map is the most reliable answer; if the click landed on the small
		-- "#prestige" child label, use its parent row's player
		if bestD then
			local pl = lbMap[bestD]
			if not pl then
				local pa
				pcall(function() pa = addrOf(bestD.Parent) end)
				if pa then
					for k, v in pairs(lbMap) do
						if addrOf(k) == pa then pl = v break end
					end
				end
			end
			if pl then return pl end
		end

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
	-- leaderboard tinting is skipped while dragging / orbiting / zooming (it is the heavy part of this tick)
	if not dragging and (now - interactAt) > 0.3 then pcall(tintTick, now) end
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
	pcall(function()
		for p, d in pairs(Data) do
			if d.revealed then
				setHidden(p, true)
				d.revealed = false
			end
		end
	end)
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

local clampOverlay
do
local vpX, vpY, vpAt = nil, nil, 0
function clampOverlay()
	local now = tick()
	if not vpX or now - vpAt > 1 then
		vpAt = now
		local ok, w, h = pcall(function()
			local v = workspace.CurrentCamera.ViewportSize
			return v.X, v.Y
		end)
		if ok and type(w) == "number" then vpX, vpY = w, h end
	end
	if vpX then
		ovX = clamp(ovX, 6, math.max(6, vpX - 60))
		ovY = clamp(ovY, 6, math.max(6, vpY - 40))
	end
	if ovX < 6 then ovX = 6 end
	if ovY < 6 then ovY = 6 end
end
end

local function handleClicks()
	local d1, d2 = inp.m1, inp.m2
	local edge1, edge2 = d1 and not prev1, d2 and not prev2
	prev1, prev2 = d1, d2
	local clicked = edge1 or edge2
	local active = inp.active

	-- (overlay dragging is handled by updateDrag, first thing in the frame)

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
--   hold RIGHT MOUSE + drag = rotate, A / D or the arrow keys also orbit around the player.
--   zoom = mouse wheel scroll, or W / S, PageUp / PageDown, = / -.
-- This only reads input and moves the TARGETS (camYaw / camPitch / camDistTarget); cfFollow eases the shown camera toward them.
local updateOrbit
do
local lastOrbitT, rmbWas, lastMX, lastMY = tick(), false, nil, nil
local vpW, vpH, vpAt = nil, nil, 0
local deltaFails = 0                       -- GetMouseDelta errors; after a few we stop calling it every frame
local keys, keysAt = { l = false, r = false, u = false, d = false, zi = false, zo = false }, 0
local function readVP() local v = workspace.CurrentCamera.ViewportSize; return v.X, v.Y end
local function getMouseDelta() return UserInputService:GetMouseDelta() end

-- constant-speed zoom: delta is in studs (negative = in, positive = out)
local function zoomBy(delta)
	camDistTarget = clamp(camDistTarget + delta, MIN_DIST, MAX_DIST)
end

-- the orbit keys are read every KEY_POLL seconds and the state reused in between (the camera still moves every frame, by dt)
local function pollKeys(now)
	if now - keysAt < KEY_POLL then return end
	keysAt = now
	keys.l  = keyDown(0x25) or keyDown(0x41)                           -- Left arrow / A
	keys.r  = keyDown(0x27) or keyDown(0x44)                           -- Right arrow / D
	keys.u  = keyDown(0x26)                                            -- Up arrow
	keys.d  = keyDown(0x28)                                            -- Down arrow
	keys.zi = keyDown(0x57) or keyDown(0x21) or keyDown(0xBB)          -- W / PageUp / =
	keys.zo = keyDown(0x53) or keyDown(0x22) or keyDown(0xBD)          -- S / PageDown / -
end

function updateOrbit()
	local now = tick()
	local dt = now - lastOrbitT
	if dt > 0.1 then dt = 0.1 end
	lastOrbitT = now

	if not (Spectating and specMode == "cf" and inMenu and inp.active) then
		rmbWas, lastMX, lastMY, wheelAcc = false, nil, nil, 0
		return
	end

	local look = inp.m2 and not dragging

	-- mouse look
	if look then
		interactAt = now
		local mx, my = mousePos()
		local dx, dy
		if deltaFails < 8 then
			local okD, md = pcall(getMouseDelta)
			if not okD then
				deltaFails = deltaFails + 1
			elseif md and (md.X ~= 0 or md.Y ~= 0) then
				dx, dy = md.X, md.Y
			end
		end
		if not dx and rmbWas and mx and lastMX then
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
	pollKeys(now)
	if keys.l then camYaw = camYaw + KEY_TURN * dt end
	if keys.r then camYaw = camYaw - KEY_TURN * dt end
	if keys.u then camPitch = clamp(camPitch - KEY_TURN * 0.7 * dt, -1.2, 1.4) end
	if keys.d then camPitch = clamp(camPitch + KEY_TURN * 0.7 * dt, -1.2, 1.4) end

	-- zoom: wheel notches + keys (cfFollow smooths the distance)
	if wheelAcc ~= 0 then
		zoomBy(-wheelAcc * WHEEL_ZOOM)
		wheelAcc = 0
		interactAt = now
	end
	if keys.zi then zoomBy(-KEY_ZOOM * dt) end
	if keys.zo then zoomBy(KEY_ZOOM * dt) end

	if keys.l or keys.r or keys.u or keys.d or keys.zi or keys.zo then interactAt = now end
end
end

local drawOverlay, updateDrag
do
local PANEL_TITLE = "Players   [H] = Hide   [W/S] = Zoom"
local drawNextText, lastSpecDrawn = 0, nil

local function drawRow(i, d, x, y, refresh)
	local p = d.player
	local t = Rows[p]
	if not t then t = newText(14, 2); Rows[p] = t; refresh = true end
	if not t then return end
	if refresh then
		local nm = d.full or ""
		local pre = (d.prestige and d.prestige > 0) and ("#" .. d.prestige .. " ") or ""
		setTxt(t, string.format("%s%s%s%s%s",
			(Spectating == p) and "> " or "",
			d.hidden and "[H] " or "",
			pre,
			(nm ~= "" and nm or "???"),
			(nm ~= p.Name) and (" (" .. p.Name .. ")") or ""))
		-- priority: spectated (light blue) > NOT spawned in (grey) > edict (gold) > white
		local col = d.color or WHITE
		if not d.spawned then col = GREY end
		if Spectating == p then col = LBLUE end
		setCol(t, col)
	end
	setPos(t, x, y + 6 + i * ROW_H)
	setVis(t, true)
end

-- moves the overlay while its header is held; runs first in the frame, touches only positions
function updateDrag()
	if not dragging then return end
	if not (inp.m1 and inp.active and inMenu and not uiHidden) then
		dragging = false
		return
	end
	local mx, my = mousePos()
	if not mx then return end
	local nx, ny = mx - dragOX, my - dragOY
	if nx == ovX and ny == ovY then return end
	ovX, ovY = nx, ny
	clampOverlay()
	local x, y = ovX, ovY
	setPos(Panel, x - 6, y - 6)
	setPos(Header, x, y)
	for i, d in ipairs(Order) do
		local t = Rows[d.player]
		if t then setPos(t, x, y + 6 + i * ROW_H) end
	end
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
	local refresh = not dragging and ((now >= drawNextText) or (lastSpecDrawn ~= Spectating))
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

-- same as updateDrag, but reads the mouse button itself: lets the Heartbeat / driver writers move the overlay too
function dragTick()
	if not dragging then return end
	local ok1, d1 = pcall(ismouse1pressed)
	inp.m1 = ok1 and d1 == true
	updateDrag()
end

local function frame()
	pcall(pollInput)
	pcall(updateDrag)         -- move the overlay first, right after reading the mouse
	pcall(handleHideKey)
	pcall(updateOrbit)        -- input first ...
	pcall(cfTick)             -- ... then apply it immediately (writer #1)
	pcall(handleClicks)
	if not dragging then pcall(drawOverlay) end   -- while dragging, updateDrag already moves everything
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
	conns[#conns + 1] = RunService.Heartbeat:Connect(function()
		if dragging then pcall(dragTick) else pcall(cfTick) end
	end)
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

-- wheel zoom: whichever source delivers a wheel event first is used from then on, so a notch is never counted twice
local wheelSrc = nil
local function addWheel(src, z)
	if type(z) ~= "number" or z == 0 then return end
	if wheelSrc == nil then wheelSrc = src end
	if wheelSrc == src then wheelAcc = wheelAcc + z end
end

pcall(function()
	conns[#conns + 1] = UserInputService.InputChanged:Connect(function(input)
		pcall(function()
			if input.UserInputType == Enum.UserInputType.MouseWheel then
				addWheel("uis", input.Position.Z or 0)
			end
		end)
	end)
end)

-- fallback wheel source: the Mouse object's own wheel events (some executors only deliver the wheel there)
pcall(function()
	local m = LocalPlayer:GetMouse()
	conns[#conns + 1] = m.WheelForward:Connect(function() pcall(addWheel, "mouse", 1) end)
	conns[#conns + 1] = m.WheelBackward:Connect(function() pcall(addWheel, "mouse", -1) end)
end)

end)

-- if anything above errored, stop silently: bumping the generation stops any loops that did start
if not ranOk then
	pcall(function() SP_GEN = (SP_GEN or 0) + 1 end)
end
end

--==============================================================
-- MATCHA TAB: "Rogue Lineage"
--==============================================================
UI.AddTab("Rogue Lineage", function(tab)
	if RL_GEN ~= RL.gen then return end   -- stale tab from an earlier run of this script

	local sp = tab:Section("Spectate", "Left")
	sp:Toggle(RL.specId, "Enable Spectate", RL.val("spectate"))

	local cf = tab:Section("Config", "Right")
	if tick() - RL.listAt > 3 then RL.refresh() end

	cf:Text("Current config: " .. RL.name)

	-- dropdown of saved configs + load the selected one
	cf:Combo(RL.comboId, "Saved configs", (#RL.list > 0) and RL.list or RL.none, RL.base)
	cf:Button("Load Selected Config", function()
		local okC, v = pcall(UI.GetValue, RL.comboId)
		local nm
		if okC and type(v) == "number" then nm = RL.list[math.floor(v) - RL.base + 1] end
		if nm and RL.load(nm) then
			pcall(notify, "Loaded config '" .. nm .. "'.", "Rogue Lineage", 3)
		else
			pcall(notify, "No config selected to load.", "Rogue Lineage", 4)
		end
	end)

	-- save under a new/typed name (blank = auto-named config_1, config_2, ...)
	cf:Spacing()
	cf:InputText(RL.nameId, "Save as", "")
	cf:Button("Save Config", function()
		RL.refresh()
		local okN, v = pcall(UI.GetValue, RL.nameId)
		local typed = (okN and type(v) == "string") and v or ""
		local nm = string.match(typed, "%w") and RL.clean(typed) or RL.autoName()
		if RL.save(nm) then
			pcall(UI.SetValue, RL.nameId, "")
			pcall(notify, "Saved config '" .. nm .. "'.", "Rogue Lineage", 3)
		else
			pcall(notify, "Save failed - the file was not created.", "Rogue Lineage", 5)
		end
	end)

	-- first render: push the autoloaded values into the widgets, then let the watcher below act on them
	if not RL.ready then
		for _, it in ipairs(RL.items) do pcall(UI.SetValue, it.id, RL.val(it.key)) end
		RL.select(RL.name)
		RL.ready = true
	end
end)

--==============================================================
-- START: autoload config, apply it, and watch the toggle
--==============================================================
RL.name = RL.getLast() or "default"
RL.cfg = RL.read(RL.name)
RL.refresh()

-- re-running the script: shut down any spectate copy left over from the previous run first
RL.stopSpectate()

task.spawn(function()
	pcall(RL.apply, RL.val("spectate"))
end)

task.spawn(function()
	while RL_GEN == RL.gen do
		pcall(function()
			if not RL.ready then return end
			local v = UI.GetValue(RL.specId)
			if type(v) == "boolean" then RL.apply(v) end
		end)
		pcall(wait, 0.25)
	end
end)

end)   -- end of main pcall

-- if anything in the main body errored, shut down whatever loops did start, then log it
if not mainOk then
	pcall(function() RL_GEN = (RL_GEN or 0) + 1 end)
	pcall(function() SP_GEN = (SP_GEN or 0) + 1 end)
	pcall(print, "[RogueLineage] script error: " .. tostring(mainErr))
end

end   -- end of PLACE_OK
