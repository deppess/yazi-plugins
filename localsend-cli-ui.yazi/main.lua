--- @since 26.5.6

local M = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function notify(title, content, level)
	ya.notify({ title = title, content = content, level = level or "info", timeout = 5.0 })
end

local get_ctx = ya.sync(function()
	local h   = cx.active.current.hovered
	local sel = {}
	for _, u in pairs(cx.active.selected) do
		sel[#sel + 1] = tostring(u)
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

-- ── Receive ───────────────────────────────────────────────────────────────────

local function action_receive()
	-- Runs as a background shell task (visible in task panel).
	-- Exits automatically after one complete transfer session.
	-- Sends a system notification on completion.
	local cmd = [[
localsend-cli receive --headless | {
    IFS= read -r _tline
    _total="${_tline#TOTAL:}"
    [ -z "$_total" ] && exit 0
    _out=""; _count=0
    while IFS= read -r _f; do
        _count=$((_count + 1))
        if [ "$_count" -le 2 ]; then
            [ -n "$_out" ] && _out="${_out}, "
            _out="${_out}${_f}"
        fi
    done
    [ "$_count" -eq 0 ] && exit 0
    if [ "$_count" -ne "$_total" ]; then
        notify-send "LocalSend" "Received $_count/$_total files"
    elif [ "$_count" -le 2 ]; then
        notify-send "LocalSend" "Received: $_out"
    else
        notify-send "LocalSend" "Received $_count files"
    fi
}
]]
	ya.emit("shell", { cmd, block = false, confirm = false })
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

	local quoted    = {}
	local basenames = {}
	for _, p in ipairs(targets) do
		quoted[#quoted + 1]    = ya.quote(p)
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

	ya.emit("shell", {
		"localsend-cli send --to " .. ya.quote(ip) .. " " .. table.concat(quoted, " ")
			.. " && notify-send 'LocalSend' " .. ya.quote(ok_msg)
			.. " || notify-send 'LocalSend' 'Send failed'",
		block   = false,
		confirm = false,
	})
end

-- ── Entry ─────────────────────────────────────────────────────────────────────

function M:entry(job)
	local cmd = job.args[1]
	if     cmd == "receive" then action_receive()
	elseif cmd == "send"    then action_send()
	end
end

return M
