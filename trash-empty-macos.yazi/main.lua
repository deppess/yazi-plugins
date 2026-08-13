--- @since 25.5.31
-- Clear the macOS trash: ~/.Trash, plus every mounted volume's per-user
-- .Trashes/<uid> directory -- no prompts, instant action.
--
-- Volumes are discovered generically under /Volumes, so anything currently
-- mounted is covered automatically -- including /Volumes/Media only while
-- its encrypted APFS volume is unlocked (see crypter-macos.yazi); locked,
-- it simply isn't there to scan. The boot volume shows up under /Volumes as
-- a symlink rather than a real directory, so it's skipped for free.
--
-- macOS counterpart to trash-empty.yazi (which targets XDG trash + .Trash-*
-- dirs via trash-cli on Linux). See README for details.

local M = {}

local function notify(message, level)
	ya.notify({
		title = "Trash Clear",
		content = message,
		level = level or "info",
		timeout = 3.0,
	})
end

local function format_size(bytes)
	if bytes == 0 then
		return "0 B"
	end

	local units = { "B", "KB", "MB", "GB", "TB" }
	local unit_index = 1
	local size = bytes

	while size >= 1024 and unit_index < #units do
		size = size / 1024
		unit_index = unit_index + 1
	end

	return string.format("%.1f %s", size, units[unit_index])
end

-- BSD `du` (macOS) has no `-b`; `-k` is the smallest unit it offers.
local function get_dir_size(path)
	local child = Command("sh")
		:arg({ "-c", string.format("du -sk %s 2>/dev/null | awk '{print $1}'", ya.quote(path)) })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:spawn()

	if not child then
		return 0
	end

	local output = child:wait_with_output()
	if output and output.status and output.status.success then
		return (tonumber(output.stdout:match("^%s*(%d+)")) or 0) * 1024
	end

	return 0
end

local function count_items(path)
	local child = Command("sh")
		:arg({ "-c", string.format("find %s -mindepth 1 2>/dev/null | wc -l", ya.quote(path)) })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:spawn()

	if not child then
		return 0
	end

	local output = child:wait_with_output()
	if output and output.status and output.status.success then
		return tonumber(output.stdout:match("^%s*(%d+)")) or 0
	end

	return 0
end

-- Delete everything *inside* path, leaving the directory itself intact --
-- ~/.Trash and .Trashes/<uid> are expected to keep existing with their
-- original ownership/permissions/sticky bit, not be recreated from scratch.
local function clear_dir_contents(path)
	return Command("sh")
		:arg({ "-c", string.format("find %s -mindepth 1 -print0 2>/dev/null | xargs -0 rm -rf", ya.quote(path)) })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:spawn()
		:wait()
end

local function path_is_dir(path)
	local cha, _ = fs.cha(Url(path), false)
	return cha and cha.is_dir or false
end

local function get_uid()
	local output, _ = Command("id"):arg({ "-u" }):stdout(Command.PIPED):output()
	if not output or not output.status.success then
		return nil
	end
	return output.stdout:match("^%s*(%d+)")
end

-- Directories directly under /Volumes -- real mounted volumes only. The
-- boot volume shows up as a *symlink* (e.g. "Macintosh HD" -> "/"), so
-- filtering to real directories skips it for free, no name-matching needed.
local function list_mounted_volumes()
	local child = Command("sh")
		:arg({ "-c", "find /Volumes -mindepth 1 -maxdepth 1 -type d 2>/dev/null" })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:spawn()

	local volumes = {}
	if not child then
		return volumes
	end

	local output = child:wait_with_output()
	if output and output.status and output.status.success then
		for line in output.stdout:gmatch("[^\r\n]+") do
			if line ~= "" then
				volumes[#volumes + 1] = line
			end
		end
	end

	return volumes
end

-- Every trash location currently present: ~/.Trash, plus each mounted
-- volume's .Trashes/<uid> when it exists.
local function collect_trash_dirs(uid)
	local dirs = { os.getenv("HOME") .. "/.Trash" }

	for _, volume in ipairs(list_mounted_volumes()) do
		local candidate = volume .. "/.Trashes/" .. uid
		if path_is_dir(candidate) then
			dirs[#dirs + 1] = candidate
		end
	end

	return dirs
end

local function clear_trash()
	if ya.target_os() ~= "macos" then
		notify("This plugin only supports macOS", "error")
		return false
	end

	local uid = get_uid()
	if not uid then
		notify("Failed to determine current user id", "error")
		return false
	end

	local dirs = collect_trash_dirs(uid)

	local item_count, size_before = 0, 0
	for _, dir in ipairs(dirs) do
		item_count = item_count + count_items(dir)
		size_before = size_before + get_dir_size(dir)
	end

	if item_count == 0 then
		notify("Trash is already empty", "info")
		return true
	end

	for _, dir in ipairs(dirs) do
		clear_dir_contents(dir)
	end

	notify(
		string.format(
			"Emptied %d items | %s freed | %d locations cleared",
			item_count,
			format_size(size_before),
			#dirs
		),
		"info"
	)
	return true
end

-- Entry point
function M:entry()
	clear_trash()
end

return M
