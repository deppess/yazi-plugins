--- @since 26.5.6
-- Mount and lock an encrypted APFS volume at a chosen mount point.

local M = {}

local set_state = ya.sync(function(state, key, value) state[key] = value end)
local get_state = ya.sync(function(state, key) return state[key] end)

local STATE = {
	VOLUME_NAME = "volume_name",
	MOUNT_POINT = "mount_point",
	MAX_RETRIES = "max_retries",
	INITIALIZED = "initialized",
}

local function notify(content, level)
	ya.notify({ title = "Crypter", content = content, level = level or "info", timeout = 3 })
end

local function expand_path(path)
	if path:sub(1, 1) == "~" then
		return (os.getenv("HOME") or "") .. path:sub(2)
	end
	return path
end

local function command_output(command, args)
	local output, err = Command(command):arg(args):stdout(Command.PIPED):stderr(Command.PIPED):output()
	if not output then
		return nil, tostring(err)
	end
	return output
end

local function error_message(output, fallback)
	if output and output.stderr and output.stderr ~= "" then
		return output.stderr:gsub("%s+$", "")
	end
	return fallback
end

-- The device node remains stable whether the APFS volume is locked or mounted.
local function device_node(volume_name)
	local output, err = command_output("diskutil", { "info", volume_name })
	if not output or not output.status.success then
		return nil, error_message(output, err or "diskutil info failed")
	end

	local device = output.stdout:match("\n%s*Device Node:%s+(%S+)")
	if not device then
		return nil, "Could not resolve the APFS device"
	end
	return device
end

-- The live kernel mount table is authoritative for toggle decisions.
local function current_mount(device)
	local output = command_output("mount", {})
	if not output or not output.status.success then
		return nil
	end

	for line in output.stdout:gmatch("[^\r\n]+") do
		local mounted_device, path = line:match("^(%S+) on (.-) %(")
		if mounted_device == device then
			return path
		end
	end
	return nil
end

local function ensure_mount_point(path)
	local attributes = fs.cha(Url(path), false)
	if attributes then
		if attributes.is_dir then
			return true
		end
		return false, "Mount point exists but is not a directory: " .. path
	end

	local output, err = command_output("mkdir", { "-p", path })
	if not output or not output.status.success then
		return false, error_message(output, err or "could not create mount point")
	end
	return true
end

local function mount_volume(device, mount_point)
	local output, err = command_output("diskutil", { "mount", "-mountPoint", mount_point, device })
	if output and output.status.success then
		return true
	end
	return false, error_message(output, err or "diskutil mount failed")
end

-- diskutil's Locked: field is only consulted after a mount failure to avoid
-- treating unrelated mount-point errors as password failures.
local function is_locked(device)
	local output, err = command_output("diskutil", { "info", device })
	if not output or not output.status.success then
		return nil, error_message(output, err or "diskutil info failed")
	end
	local locked = output.stdout:match("\n%s*Locked:%s+(%S+)")
	if not locked then
		return nil, "Could not determine whether the volume is locked"
	end
	return locked == "Yes"
end

local function unlock_volume(device, mount_point, max_retries)
	for attempt = 1, max_retries do
		local title = attempt == 1 and "Unlock Encrypted Volume"
			or string.format("Invalid Password (%d/%d)", attempt - 1, max_retries)
		local password, event = ya.input({
			title = title,
			value = "",
			placeholder = "Enter password",
			obscure = true,
			pos = { "center", w = 60 },
		})
		if event ~= 1 then
			notify("Unlock cancelled", "warn")
			return false
		end

		local child, spawn_err = Command("diskutil")
			:arg({ "apfs", "unlockVolume", device, "-mountpoint", mount_point, "-stdinpassphrase" })
			:stdin(Command.PIPED)
			:stdout(Command.PIPED)
			:stderr(Command.PIPED)
			:spawn()
		if not child then
			notify("Failed to start diskutil: " .. tostring(spawn_err), "error")
			return false
		end

		child:write_all(password .. "\n")
		child:flush()
		local output, wait_err = child:wait_with_output()
		if output and output.status.success then
			notify("Unlocked and mounted at " .. mount_point, "info")
			return true
		end
		if attempt == max_retries then
			notify("Unlock failed: " .. error_message(output, tostring(wait_err)), "error")
			return false
		end
	end
	return false
end

local function unmount_volume(path)
	local output, err = command_output("diskutil", { "unmount", path })
	if output and output.status.success then
		return true
	end

	local dissenters, only_yazi = {}, true
	for pid, executable in (output and output.stderr or ""):gmatch("dissented by PID (%d+) %(([^%)]+)%)") do
		local process = executable:match("([^/]+)$") or executable
		dissenters[#dissenters + 1] = process .. " (PID " .. pid .. ")"
		only_yazi = only_yazi and process == "yazi"
	end
	if #dissenters == 0 then
		return false, error_message(output, err or "diskutil unmount failed")
	end
	if not only_yazi then
		return false, "Unmount blocked by " .. table.concat(dissenters, ", ")
	end

	output, err = command_output("diskutil", { "unmount", "force", path })
	if output and output.status.success then
		return true
	end
	return false, "Force unmount failed: " .. error_message(output, err or "unknown error")
end

local function lock_volume(device)
	local output, err = command_output("diskutil", { "apfs", "lockVolume", device })
	if output and output.status.success then
		return true
	end
	local message = error_message(output, err or "diskutil lockVolume failed")
	if message:lower():find("already locked", 1, true) then
		return true
	end
	return false, message
end

local function open_volume(device, mount_point, max_retries)
	local ready, ready_err = ensure_mount_point(mount_point)
	if not ready then
		notify(ready_err, "error")
		return
	end

	local mounted, mount_err = mount_volume(device, mount_point)
	if mounted then
		notify("Mounted at " .. mount_point, "info")
		return
	end

	local locked, state_err = is_locked(device)
	if locked == true then
		unlock_volume(device, mount_point, max_retries)
	elseif locked == false then
		notify("Failed to mount at " .. mount_point .. ": " .. mount_err, "error")
	else
		notify("Failed to mount at " .. mount_point .. ": " .. (state_err or mount_err), "error")
	end
end

local function toggle(volume_name, mount_point, max_retries)
	local device, device_err = device_node(volume_name)
	if not device then
		notify("Could not resolve '" .. volume_name .. "': " .. device_err, "error")
		return
	end

	local mounted_at = current_mount(device)
	if not mounted_at then
		open_volume(device, mount_point, max_retries)
		return
	end
	if mounted_at ~= mount_point then
		notify("Mounted at " .. mounted_at .. "; refusing to remount automatically", "warn")
		return
	end

	local unmounted, unmount_err = unmount_volume(mounted_at)
	if not unmounted then
		notify(unmount_err, "error")
		return
	end
	local locked, lock_err = lock_volume(device)
	if locked then
		notify("Locked and unmounted", "info")
	else
		notify("Unmounted, but failed to lock: " .. lock_err, "error")
	end
end

---@param opts? {volume_name?: string, mount_point?: string, max_retries?: number}
function M:setup(opts)
	if opts and type(opts) ~= "table" then
		return
	end

	local volume_name = (opts and opts.volume_name) or "Media"
	local mount_point = expand_path((opts and opts.mount_point) or "~/Media")
	local max_retries = (opts and opts.max_retries) or 3
	if type(volume_name) ~= "string" or volume_name == "" then
		return
	end
	if type(mount_point) ~= "string" or mount_point == "" then
		return
	end
	if type(max_retries) ~= "number" or max_retries < 1 or max_retries % 1 ~= 0 then
		return
	end

	set_state(STATE.VOLUME_NAME, volume_name)
	set_state(STATE.MOUNT_POINT, mount_point)
	set_state(STATE.MAX_RETRIES, max_retries)
	set_state(STATE.INITIALIZED, true)
end

function M:entry()
	if ya.target_os() ~= "macos" then
		notify("This plugin only supports macOS", "error")
		return
	end
	if not get_state(STATE.INITIALIZED) then
		M:setup()
	end
	toggle(
		get_state(STATE.VOLUME_NAME),
		get_state(STATE.MOUNT_POINT),
		get_state(STATE.MAX_RETRIES)
	)
end

return M
