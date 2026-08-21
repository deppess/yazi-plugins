--- @since 25.5.31
-- Clear ALL trash volumes system-wide - no prompts, instant action.
--
-- WARNING: this clears the XDG trash AND every .Trash-* directory found at
-- the root of every currently mounted volume (external drives, network
-- shares, anything mounted right now) -- not just your home trash. There is
-- no confirmation prompt by design. See README for details.

local M = {}

-- Check if command is available
local function is_command_available(cmd)
	local stat_cmd = string.format("command -v %s >/dev/null 2>&1", cmd)
	local cmd_exists = os.execute(stat_cmd)
	return cmd_exists == true or cmd_exists == 0
end

-- Send a notification
local function notify(message, level)
	ya.notify({
		title = "Trash Clear",
		content = message,
		level = level or "info",
		timeout = 3.0,
	})
end

-- Format bytes to human readable
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

-- Get directory size in bytes
local function get_dir_size(path)
	local child = Command("sh")
		:arg({ "-c", string.format("du -sb %s 2>/dev/null | awk '{print $1}'", ya.quote(path)) })
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

-- Get all real mount points on the system via findmnt
-- Excludes virtual/pseudo filesystems (proc, sysfs, devtmpfs, etc.)
local function get_all_mount_points()
	local child = Command("sh")
		:arg({
			"-c",
			"findmnt -rn -o TARGET,FSTYPE 2>/dev/null | awk '$2 !~ /^(proc|sysfs|devtmpfs|devpts|tmpfs|cgroup|cgroup2|pstore|efivarfs|bpf|tracefs|securityfs|debugfs|hugetlbfs|mqueue|fusectl|overlay|ramfs|autofs|squashfs|iso9660)$/ {print $1}'",
		})
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:spawn()

	local mounts = {}
	if not child then
		return mounts
	end

	local output = child:wait_with_output()
	if output and output.status and output.status.success then
		for line in output.stdout:gmatch("[^\r\n]+") do
			if line ~= "" then
				mounts[#mounts + 1] = line
			end
		end
	end

	return mounts
end

-- Find all .Trash-* dirs at the root of a mount point (depth 1)
local function find_trash_dirs(mount)
	local child = Command("sh")
		:arg({
			"-c",
			string.format("find %s -maxdepth 1 -name '.Trash-*' -type d 2>/dev/null", ya.quote(mount)),
		})
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:spawn()

	local dirs = {}
	if not child then
		return dirs
	end

	local output = child:wait_with_output()
	if output and output.status and output.status.success then
		for line in output.stdout:gmatch("[^\r\n]+") do
			if line ~= "" then
				dirs[#dirs + 1] = line
			end
		end
	end

	return dirs
end

-- Collect every trash location on the system
-- Returns: xdg_trash path (string), raw_dirs (list of .Trash-* paths to remove)
local function collect_all_trash()
	local home = os.getenv("HOME")
	local xdg_trash = home .. "/.local/share/Trash"
	local raw_dirs = {}

	for _, mount in ipairs(get_all_mount_points()) do
		for _, trash_dir in ipairs(find_trash_dirs(mount)) do
			raw_dirs[#raw_dirs + 1] = trash_dir
		end
	end

	return xdg_trash, raw_dirs
end

-- Get total trash size across all locations
local function get_total_trash_size(xdg_trash, raw_dirs)
	local total = get_dir_size(xdg_trash)
	for _, dir in ipairs(raw_dirs) do
		total = total + get_dir_size(dir)
	end
	return total
end

-- Count items in the XDG trash via trash-list
local function get_trash_count()
	local child = Command("sh")
		:arg({ "-c", "trash-list 2>/dev/null | wc -l" })
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

-- Clear all trash
local function clear_trash()
	if ya.target_os() ~= "linux" then
		notify("✗ This plugin only supports Linux (uses findmnt/trash-cli)", "error")
		return false
	end

	if not is_command_available("trash-empty") then
		notify("✗ trash-cli not installed", "error")
		return false
	end

	local xdg_trash, raw_dirs = collect_all_trash()

	local trash_count = get_trash_count()
	local size_before = get_total_trash_size(xdg_trash, raw_dirs)

	-- Clear XDG user trash via trash-empty (handles .trashinfo files cleanly)
	local result = Command("sh")
		:arg({ "-c", "yes | trash-empty 2>/dev/null" })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:spawn()
		:wait()

	if not result or not result.success then
		notify("✗ Failed to clear trash", "error")
		return false
	end

	-- Remove the XDG trash dir itself so it's fully gone.
	-- fs.remove("dir_all", ...) is the native async API for a recursive
	-- delete -- no subshell, no quoting to get right.
	fs.remove("dir_all", Url(xdg_trash))

	-- Remove every .Trash-* dir found on all mount points.
	for _, dir in ipairs(raw_dirs) do
		fs.remove("dir_all", Url(dir))
	end

	local size_after = get_total_trash_size(xdg_trash, raw_dirs)
	local space_freed = size_before - size_after

	notify(
		string.format("✓ Emptied %d items | %s freed | %d locations cleared", trash_count, format_size(space_freed), #raw_dirs),
		"info"
	)
	return true
end

-- Entry point
function M:entry()
	clear_trash()
end

return M
