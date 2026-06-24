--- @since 26.5.6

local M = {}

-- ── State ─────────────────────────────────────────────────────────────────────
-- Tracks the one mounted profile for the session. Lost on yazi restart;
-- unmount recovers by scanning profile contexts with mountpoint(1).

local K_PROFILE = "p"
local K_CONTEXT = "c"

local set_state = ya.sync(function(state, key, val)
	state[key] = val
end)

local get_state = ya.sync(function(state, key)
	return state and state[key]
end)

-- ── Yazi context ──────────────────────────────────────────────────────────────

local get_ctx = ya.sync(function()
	local h   = cx.active.current.hovered
	local sel = {}
	for _, u in pairs(cx.active.selected) do
		sel[#sel + 1] = tostring(u)
	end
	return {
		hovered        = h and tostring(h.url) or nil,
		hovered_is_dir = h and h.cha and h.cha.is_dir or false,
		selected       = sel,
	}
end)

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function notify(title, content, level)
	ya.notify({ title = title, content = content, level = level or "info", timeout = 5.0 })
end

local function path_is_dir(path)
	local cha, _ = fs.cha(Url(path), false)
	return cha and cha.is_dir or false
end

local function is_mounted(path)
	local res = Command("mountpoint")
		:arg({ "-q", path })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:spawn()
		:wait()
	return res and res.success
end

-- Returns the first meaningful line from sfync stderr.
local function parse_err(raw)
	if not raw or raw == "" then return "Unknown error" end
	for line in raw:gmatch("[^\r\n]+") do
		local t = line:gsub("^%s+", ""):gsub("%s+$", "")
		if t ~= "" then return t end
	end
	return "Unknown error"
end

-- ── Config ────────────────────────────────────────────────────────────────────

local function load_config()
	local config_path = os.getenv("HOME") .. "/.config/sfync/config.json"
	local f = io.open(config_path, "r")
	if not f then
		return nil, "sfync config not found: " .. config_path
	end
	local raw = f:read("*a")
	f:close()

	local profiles = {}
	-- %b{} matches balanced braces, safe against nested structures.
	for name, block in raw:gmatch('"([^"]+)"%s*:%s*(%b{})') do
		local ctx  = block:match('"context"%s*:%s*"([^"]*)"')
		local host = block:match('"host"%s*:%s*"([^"]*)"')
		if ctx and ctx ~= "" then
			profiles[name] = { context = ctx, host = host or "remote" }
		end
	end

	if next(profiles) == nil then
		return nil, "no profiles with a context found in sfync config"
	end
	return profiles
end

-- Exact: path must equal profile context (dir-level actions).
local function find_exact(profiles, path)
	local p = path:gsub("/+$", "")
	for name, prof in pairs(profiles) do
		if p == prof.context then
			return name, prof
		end
	end
	return nil, nil
end

-- Prefix: path is at or under profile context (file-level actions).
local function find_parent(profiles, path)
	local p = path:gsub("/+$", "")
	for name, prof in pairs(profiles) do
		if p == prof.context or p:sub(1, #prof.context + 1) == prof.context .. "/" then
			return name, prof
		end
	end
	return nil, nil
end

-- ── Blocking shell (sync + diff) ─────────────────────────────────────────────

local function run_blocking(cmd)
	ya.emit("shell", {
		cmd .. "; printf '\\n\\nPress Enter to return...'; stty sane; read _",
		block   = true,
		confirm = false,
	})
end

-- ── Dir actions: up / down / diff ────────────────────────────────────────────

local function dir_action(sfync_sub)
	local ctx = get_ctx()
	if not ctx.hovered or not ctx.hovered_is_dir then return end

	local profiles, err = load_config()
	if not profiles then notify("SFTP Error", err, "error"); return end

	local name = find_exact(profiles, ctx.hovered)
	if not name then return end  -- silently ignore non-profile dirs

	run_blocking("sfync " .. sfync_sub .. " " .. ya.quote(name))
end

-- ── File actions: push / pull ─────────────────────────────────────────────────

-- Builds and fires one background fish script for a single profile group.
local function run_transfer(op, profile_name, host, context, items)
	local lines = { "set -l _errs" }

	for _, item in ipairs(items) do
		if path_is_dir(item) then
			-- Expand directory: sfync push/pull each contained file individually.
			lines[#lines + 1] = "for _f in (find " .. ya.quote(item) .. " -type f)"
			lines[#lines + 1] = "    sfync " .. op .. " " .. ya.quote(profile_name)
				.. " $_f || set _errs $_errs (string replace " .. ya.quote(context .. "/") .. " '' $_f)"
			lines[#lines + 1] = "end"
		else
			local base = item:match("([^/]+)$") or item
			lines[#lines + 1] = "sfync " .. op .. " " .. ya.quote(profile_name)
				.. " " .. ya.quote(item) .. " || set _errs $_errs " .. ya.quote(base)
		end
	end

	local ok_title  = op == "push" and "File Uploaded"   or "File Downloaded"
	local err_title = op == "push" and "SFTP Push Error" or "SFTP Pull Error"
	local ok_msg    = op == "push"
		and ("Uploaded to " .. host)
		or  ("Downloaded from " .. host)

	lines[#lines + 1] = "if test (count $_errs) -gt 0"
	lines[#lines + 1] = "    notify-send " .. ya.quote(err_title)
		.. " (string join '\\n' 'Failed:' $_errs)"
	lines[#lines + 1] = "else"
	lines[#lines + 1] = "    notify-send " .. ya.quote(ok_title) .. " " .. ya.quote(ok_msg)
	lines[#lines + 1] = "end"

	ya.emit("shell", {
		table.concat(lines, "\n"),
		block   = false,
		confirm = false,
	})
end

local function file_action(op)
	local ctx = get_ctx()

	local targets
	if #ctx.selected > 0 then
		targets = ctx.selected
	elseif ctx.hovered then
		targets = { ctx.hovered }
	else
		local title = op == "push" and "SFTP Push" or "SFTP Pull"
		notify(title, "Nothing selected or hovered", "warn")
		return
	end

	local profiles, err = load_config()
	if not profiles then notify("SFTP Error", err, "error"); return end

	-- Group targets by profile; collect items with no matching profile.
	local groups    = {}
	local unmatched = {}

	for _, target in ipairs(targets) do
		local name, profile = find_parent(profiles, target)
		if name then
			if not groups[name] then
				groups[name] = { host = profile.host, context = profile.context, items = {} }
			end
			groups[name].items[#groups[name].items + 1] = target
		else
			unmatched[#unmatched + 1] = target:match("([^/]+)$") or target
		end
	end

	if #unmatched > 0 then
		local err_title = op == "push" and "SFTP Push Error" or "SFTP Pull Error"
		notify(err_title, "Not in any profile:\n" .. table.concat(unmatched, "\n"), "error")
	end

	-- Launch one background script per profile group.
	for name, group in pairs(groups) do
		run_transfer(op, name, group.host, group.context, group.items)
	end
end

-- ── Mount ─────────────────────────────────────────────────────────────────────

local function action_mount()
	local ctx = get_ctx()
	if not ctx.hovered or not ctx.hovered_is_dir then return end

	local profiles, err = load_config()
	if not profiles then notify("SFTP Error", err, "error"); return end

	local name, profile = find_exact(profiles, ctx.hovered)
	if not name then return end  -- silently ignore

	-- Enforce single-mount limit via state.
	local current = get_state(K_PROFILE)
	if current then
		notify("SFTP Mount Error",
			"Already mounted: " .. current .. ". Press vM to unmount first.",
			"error")
		return
	end

	-- Filesystem guard: catches external mounts or state loss after restart.
	if is_mounted(profile.context) then
		notify("SFTP Mount", name .. " is already mounted", "warn")
		set_state(K_PROFILE, name)
		set_state(K_CONTEXT, profile.context)
		ya.emit("cd", { profile.context })
		return
	end

	notify("SFTP Mount", "Mounting " .. name .. "...", "info")

	local out, cerr = Command("sfync")
		:arg({ "mount", name })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()

	if out and out.status.success then
		set_state(K_PROFILE, name)
		set_state(K_CONTEXT, profile.context)
		ya.emit("cd", { profile.context })
		notify("SFTP Mount", "Mounted " .. name, "info")
	else
		notify("SFTP Mount Error",
			parse_err((out and out.stderr) or tostring(cerr or "")),
			"error")
	end
end

-- ── Unmount ───────────────────────────────────────────────────────────────────

local function action_unmount()
	local name    = get_state(K_PROFILE)
	local context = get_state(K_CONTEXT)

	-- State recovery: scan all profile contexts if state was lost (yazi restart).
	if not name then
		local profiles, perr = load_config()
		if not profiles then notify("SFTP Error", perr, "error"); return end

		local count = 0
		for pname, p in pairs(profiles) do
			if is_mounted(p.context) then
				name    = pname
				context = p.context
				count   = count + 1
			end
		end

		if count == 0 then
			notify("SFTP Unmount", "Nothing is mounted", "warn")
			return
		end
		if count > 1 then
			notify("SFTP Unmount Error",
				"Multiple profiles mounted — run: sfync unmount --all",
				"error")
			return
		end
	end

	local out, cerr = Command("sfync")
		:arg({ "unmount", name })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()

	if out and out.status.success then
		set_state(K_PROFILE, nil)
		set_state(K_CONTEXT, nil)
		ya.emit("cd", { context })
		notify("SFTP Unmount", "Unmounted " .. name, "info")
	else
		notify("SFTP Unmount Error",
			parse_err((out and out.stderr) or tostring(cerr or "")),
			"error")
	end
end

-- ── Entry ─────────────────────────────────────────────────────────────────────

function M:entry(job)
	local cmd = job.args[1]
	if     cmd == "up"      then dir_action("up")
	elseif cmd == "down"    then dir_action("down")
	elseif cmd == "du"      then dir_action("diff up")
	elseif cmd == "dd"      then dir_action("diff down")
	elseif cmd == "push"    then file_action("push")
	elseif cmd == "pull"    then file_action("pull")
	elseif cmd == "mount"   then action_mount()
	elseif cmd == "unmount" then action_unmount()
	end
end

return M
