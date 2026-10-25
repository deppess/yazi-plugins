--- @since 26.8.15

local M = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function notify(title, content, level)
	ya.notify({ title = title, content = content, level = level or "info", timeout = 5.0 })
end

local function desktop_notify(title, content)
	if ya.target_os() == "macos" then
		local script = [[on run argv
	display notification (item 2 of argv) with title (item 1 of argv)
end run]]
		Command("osascript"):arg({ "-e", script, title, content }):output()
	else
		Command("notify-send"):arg({ title, content }):output()
	end
end

local get_ctx = ya.sync(function()
	local h   = cx.active.current.hovered
	local sel = {}
	for _, file in pairs(cx.active.selected) do
		sel[#sel + 1] = tostring(file.url)
	end
	return {
		hovered  = h and tostring(h.url) or nil,
		selected = sel,
	}
end)

-- ── Config ────────────────────────────────────────────────────────────────────

-- Read favorites directly from config (instant, no network scan needed).
local function load_favorites()
	local path = os.getenv("HOME") .. "/.config/localsend-cli/config.toml"
	local f = io.open(path, "r")
	if not f then return {} end
	local content = f:read("*a")
	f:close()

	local favs     = {}
	local in_favs  = false
	for line in content:gmatch("[^\n]+") do
		if line:match("^%[favorites%]") then
			in_favs = true
		elseif line:match("^%[") then
			in_favs = false
		elseif in_favs then
			local name, ip = line:match('^%s*"([^"]+)"%s*=%s*"([^"]+)"')
			if name and ip then
				favs[#favs + 1] = { alias = name, ip = ip }
			end
		end
	end
	return favs
end

-- Read [whitelist] enabled directly from config, same technique as
-- load_favorites(). Fails safe: if the file can't be read/parsed, treat
-- whitelist as disabled so the exposure warning still fires.
local function whitelist_enabled()
	local path = os.getenv("HOME") .. "/.config/localsend-cli/config.toml"
	local f = io.open(path, "r")
	if not f then return false end
	local content = f:read("*a")
	f:close()

	local in_wl = false
	for line in content:gmatch("[^\n]+") do
		if line:match("^%[whitelist%]") then
			in_wl = true
		elseif line:match("^%[") then
			in_wl = false
		elseif in_wl then
			local val = line:match('^%s*enabled%s*=%s*(%a+)')
			if val then return val == "true" end
		end
	end
	return false
end

-- ── Receive ───────────────────────────────────────────────────────────────────

local function action_receive()
	if not whitelist_enabled() then
		notify("LocalSend", "Whitelist is disabled — this will accept files from any device on the LAN. Enable [whitelist] in config.toml to restrict this.", "warn")
	end

	local output, err = Command("localsend-cli")
		:arg({ "receive", "--headless" })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()
	if not output then
		notify("LocalSend", "Could not start receive: " .. tostring(err), "error")
		return
	end

	local total, files = nil, {}
	for line in output.stdout:gmatch("[^\r\n]+") do
		if not total then
			total = tonumber(line:match("^TOTAL:(%d+)$"))
		else
			files[#files + 1] = line
		end
	end
	if #files == 0 then
		if not output.status.success then
			notify("LocalSend", output.stderr:gsub("%s+$", "") ~= "" and output.stderr:gsub("%s+$", "") or "Receive failed", "error")
		end
		return
	end

	local message
	if total and #files ~= total then
		message = string.format("Received %d/%d files", #files, total)
	elseif #files <= 2 then
		message = "Received: " .. table.concat(files, ", ")
	else
		message = string.format("Received %d files", #files)
	end
	desktop_notify("LocalSend", message)
end

-- ── Send ──────────────────────────────────────────────────────────────────────

local function action_send()
	-- Build device list from favorites (instant). Fall back to live discover
	-- if favorites are empty.
	local devices = load_favorites()

	if #devices == 0 then
		local out = Command("localsend-cli")
			:arg({ "discover" })
			:stdout(Command.PIPED)
			:stderr(Command.NULL)
			:output()
		if out and out.stdout and out.stdout ~= "" then
			local seen = {}
			for obj in out.stdout:gmatch("%b{}") do
				local alias = obj:match('"alias"%s*:%s*"([^"]*)"')
				local ip    = obj:match('"ip"%s*:%s*"([^"]*)"')
				if alias and ip and not seen[ip] then
					seen[ip] = true
					devices[#devices + 1] = { alias = alias, ip = ip }
				end
			end
		end
	end

	if #devices == 0 then
		notify("LocalSend", "No devices found", "warn")
		return
	end

	-- Numbered picker (keys 1–9)
	local cands = {}
	for i, d in ipairs(devices) do
		cands[#cands + 1] = { on = tostring(i), desc = d.alias .. "  " .. d.ip }
		if i == 9 then break end
	end

	local idx = ya.which { cands = cands }
	if not idx then return end

	local ip = devices[idx].ip

	-- Get selected files, fall back to hovered
	local ctx = get_ctx()
	local targets
	if #ctx.selected > 0 then
		targets = ctx.selected
	elseif ctx.hovered then
		targets = { ctx.hovered }
	else
		notify("LocalSend", "Nothing selected or hovered", "warn")
		return
	end

	local basenames = {}
	for _, p in ipairs(targets) do
		basenames[#basenames + 1] = p:match("([^/]+)$") or p
	end

	local n = #basenames
	local ok_msg
	if n == 1 then
		ok_msg = "Sent: " .. basenames[1]
	elseif n == 2 then
		ok_msg = "Sent: " .. basenames[1] .. ", " .. basenames[2]
	else
		ok_msg = "Sent " .. n .. " files"
	end

	local args = { "send", "--to", ip }
	for _, path in ipairs(targets) do
		args[#args + 1] = path
	end
	local output, err = Command("localsend-cli"):arg(args):stdout(Command.PIPED):stderr(Command.PIPED):output()
	if output and output.status.success then
		desktop_notify("LocalSend", ok_msg)
	else
		local detail = output and output.stderr:gsub("%s+$", "") or tostring(err)
		notify("LocalSend", detail ~= "" and "Send failed: " .. detail or "Send failed", "error")
		desktop_notify("LocalSend", "Send failed")
	end
end

-- ── Entry ─────────────────────────────────────────────────────────────────────

function M:entry(job)
	local cmd = job.args[1]
	if     cmd == "receive" then action_receive()
	elseif cmd == "send"    then action_send()
	end
end

return M
